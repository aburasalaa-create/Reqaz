-- RMS customer billing against customer purchase orders: advance, progress, milestone and final invoices,
-- advance recovery, retention release, and the matching ledger postings.
--
-- Rules
--   * An invoice can name the customer order it bills. Everything billed on an order (excluding advances, after credit notes)
--     can never exceed the order amount.
--   * Advance invoices are taxed when issued and credited to "advances from customers", not revenue.
--   * Later invoices recover the advance as a deduction before VAT (advance_recovery, excl. VAT), so VAT is not charged twice;
--     the recovery cannot exceed the advance still open on the project.
--   * Progress claims bill the change in cumulative % complete per order line since the last issued claim.
--   * Retention held by the customer is collected later as a "retention" receipt against the invoice that withheld it.

alter table public.invoices
  add column customer_po_id uuid references public.customer_pos (id) on delete restrict,
  add column billing_type text not null default 'standard' check (billing_type in ('standard', 'advance', 'progress', 'milestone', 'final')),
  add column claim_no integer,
  add column advance_recovery numeric(18, 2) not null default 0 check (advance_recovery >= 0),
  add column retention_received numeric(18, 2) not null default 0;
create index invoices_customer_po_idx on public.invoices (customer_po_id);

alter table public.invoice_lines
  add column customer_po_line_id uuid references public.customer_po_lines (id) on delete restrict,
  add column progress_pct numeric(7, 4) check (progress_pct is null or (progress_pct > 0 and progress_pct <= 100));

create table public.customer_po_milestones (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references public.customer_pos (id) on delete cascade,
  sort_order integer not null default 0,
  label text not null check (length(trim(label)) > 0),
  percent numeric(7, 4) check (percent > 0 and percent <= 100),
  amount numeric(18, 2) check (amount > 0),
  due_date date,
  created_at timestamptz not null default now(),
  constraint customer_po_milestones_value check ((percent is null) <> (amount is null))
);
create index customer_po_milestones_po_idx on public.customer_po_milestones (po_id, sort_order);
alter table public.invoices add column milestone_id uuid references public.customer_po_milestones (id) on delete restrict;

-- ---------------------------------------------------------------------------
-- Calculation (authoritative)
--   taxable     = Σ line net − advance recovered
--   VAT         = Σ per VAT rate of round(net at that rate × rate%, 2); the recovery reduces the standard-rate group
--   total       = taxable + VAT;  retention = round(taxable × retention%, 2)
--   payable     = total − retention − advance deduction (legacy, entered gross)
-- ---------------------------------------------------------------------------

create or replace function public.recalculate_invoice(p_invoice_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  inv public.invoices%rowtype;
  v_sub numeric; v_disc numeric; v_net numeric; v_taxable numeric; v_vat numeric; v_ret numeric;
begin
  select * into inv from public.invoices where id = p_invoice_id for update;
  if not found or inv.status <> 'draft' then return; end if;
  select coalesce(sum(gross_amount), 0), coalesce(sum(discount_amount), 0), coalesce(sum(net_amount), 0)
    into v_sub, v_disc, v_net from public.invoice_lines where invoice_id = p_invoice_id;
  select coalesce(sum(round((net - case when rn = 1 then inv.advance_recovery else 0 end) * vat_rate / 100, 2)), 0) into v_vat from (
    select vat_category, vat_rate, sum(net_amount) as net,
           row_number() over (order by (vat_category = 'S') desc, vat_rate desc) as rn
      from public.invoice_lines where invoice_id = p_invoice_id group by vat_category, vat_rate
  ) c;
  v_taxable := v_net - inv.advance_recovery;
  v_ret := round(v_taxable * inv.retention_pct / 100, 2);
  perform set_config('rms.invoice_calc', p_invoice_id::text, true);
  update public.invoices
     set subtotal = v_sub, discount_total = v_disc, taxable_amount = v_taxable, vat_total = v_vat,
         total_amount = v_taxable + v_vat, retention_amount = v_ret,
         amount_payable = v_taxable + v_vat - v_ret - inv.advance_deduction
   where id = p_invoice_id;
  perform set_config('rms.invoice_calc', '', true);
end $$;

drop trigger invoice_params_recalc on public.invoices;
create trigger invoice_params_recalc after update of retention_pct, advance_deduction, advance_recovery on public.invoices
  for each row execute function public.invoice_params_recalc();

create or replace function public.invoices_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_calc boolean := coalesce(current_setting('rms.invoice_calc', true), '') = new.id::text;
  v_issue boolean := coalesce(current_setting('rms.invoice_issue', true), '') = new.id::text;
  v_paid boolean := coalesce(current_setting('rms.invoice_paid', true), '') = new.id::text;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.number is not null or new.issued_at is not null or new.zatca_qr is not null then
      raise exception 'Invoices are created as drafts' using errcode = 'check_violation';
    end if;
    if new.customer_po_id is not null then
      if (select customer_id from public.customer_pos where id = new.customer_po_id) <> new.customer_id then
        raise exception 'The customer order belongs to another customer' using errcode = 'check_violation';
      end if;
      if (select status from public.customer_pos where id = new.customer_po_id) not in ('accepted', 'active', 'completed') then
        raise exception 'Only accepted customer orders can be invoiced' using errcode = 'check_violation';
      end if;
    end if;
    new.subtotal := 0; new.discount_total := 0; new.taxable_amount := 0; new.vat_total := 0;
    new.total_amount := 0; new.retention_amount := 0; new.amount_payable := 0 - new.advance_deduction; new.amount_paid := 0;
    new.retention_received := 0;
    return new;
  end if;

  if v_paid then
    if (to_jsonb(new) - 'amount_paid' - 'retention_received' - 'updated_at') <> (to_jsonb(old) - 'amount_paid' - 'retention_received' - 'updated_at') then
      raise exception 'Payment update may only change the amount paid' using errcode = 'insufficient_privilege';
    end if;
    return new;
  end if;

  if old.status <> 'draft' and not v_issue then
    if (to_jsonb(new) - 'pdf_attachment_id' - 'updated_at') <> (to_jsonb(old) - 'pdf_attachment_id' - 'updated_at')
       or (old.pdf_attachment_id is not null and new.pdf_attachment_id is distinct from old.pdf_attachment_id) then
      raise exception 'An issued invoice cannot be changed; issue a credit or debit note instead' using errcode = 'insufficient_privilege';
    end if;
    return new;
  end if;

  if not v_issue and (new.status, new.number, new.issued_at, new.issue_date, new.issued_by, new.seller_snapshot, new.buyer_snapshot,
       new.zatca_qr, new.cancelled_at, new.cancelled_by, new.cancel_reason, new.amount_paid, new.retention_received)
     is distinct from (old.status, old.number, old.issued_at, old.issue_date, old.issued_by, old.seller_snapshot, old.buyer_snapshot,
       old.zatca_qr, old.cancelled_at, old.cancelled_by, old.cancel_reason, old.amount_paid, old.retention_received) then
    raise exception 'Use the issue or cancel action to change an invoice status' using errcode = 'insufficient_privilege';
  end if;
  if not v_calc and not v_issue and (new.subtotal, new.discount_total, new.taxable_amount, new.vat_total, new.total_amount,
       new.retention_amount, new.amount_payable)
     is distinct from (old.subtotal, old.discount_total, old.taxable_amount, old.vat_total, old.total_amount,
       old.retention_amount, old.amount_payable) then
    raise exception 'Invoice totals are calculated by the system' using errcode = 'insufficient_privilege';
  end if;
  if new.kind <> old.kind or new.original_invoice_id is distinct from old.original_invoice_id
     or (new.customer_po_id, new.billing_type, new.claim_no, new.milestone_id) is distinct from (old.customer_po_id, old.billing_type, old.claim_no, old.milestone_id)
        and not v_issue then
    raise exception 'The document type and the order it bills cannot change after creation' using errcode = 'check_violation';
  end if;
  return new;
end $$;

-- Open advance on a project (or, without a project, a customer): advances invoiced − credited − recovered so far.
create or replace function public.customer_advance_open(p_customer_id uuid, p_project_id uuid, p_exclude_invoice uuid default null) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(case when i.billing_type = 'advance' and i.kind = 'invoice' then i.taxable_amount else 0 end), 0)
       - coalesce(sum(case when i.kind = 'credit_note' and o.billing_type = 'advance' then i.taxable_amount else 0 end), 0)
       - coalesce(sum(case when i.kind = 'invoice' and i.id is distinct from p_exclude_invoice then i.advance_recovery else 0 end), 0)
    from public.invoices i left join public.invoices o on o.id = i.original_invoice_id
   where i.status = 'issued' and i.customer_id = p_customer_id
     and (p_project_id is null or i.project_id = p_project_id)
$$;

-- Value billed against a customer order so far (excluding advances; credit notes deducted), before VAT and before recovery.
create or replace function public.customer_po_billed(p_po_id uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(case when i.kind = 'invoice' then i.taxable_amount + i.advance_recovery
                           when i.kind = 'debit_note' then i.taxable_amount
                           when i.kind = 'credit_note' and o.billing_type <> 'advance' then -i.taxable_amount else 0 end), 0)
    from public.invoices i left join public.invoices o on o.id = i.original_invoice_id
   where i.status = 'issued' and coalesce(i.customer_po_id, o.customer_po_id) = p_po_id
     and not (i.kind = 'invoice' and i.billing_type = 'advance')
$$;

-- Extra checks before the standard issue rules run.
create or replace function public.invoices_issue_checks() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_po public.customer_pos%rowtype; v_billed numeric; v_target numeric;
begin
  if not (old.status = 'draft' and new.status = 'issued') or new.kind = 'proforma' then return new; end if;
  if new.advance_recovery > 0 then
    if new.kind <> 'invoice' or new.billing_type = 'advance' then
      raise exception 'Only progress, milestone, final or standard invoices can recover an advance' using errcode = 'check_violation';
    end if;
    if new.advance_recovery > public.customer_advance_open(new.customer_id, new.project_id, new.id) then
      raise exception 'The advance recovered is more than the advance still open (%)', public.customer_advance_open(new.customer_id, new.project_id, new.id)
        using errcode = 'check_violation';
    end if;
    select coalesce(sum(net_amount), 0) into v_target from public.invoice_lines where invoice_id = new.id and vat_category = 'S';
    if new.advance_recovery > v_target then
      raise exception 'The advance recovered cannot be more than the standard-rated amount of the invoice' using errcode = 'check_violation';
    end if;
  end if;
  if new.customer_po_id is not null and new.kind in ('invoice', 'debit_note') and new.billing_type <> 'advance' then
    select * into v_po from public.customer_pos where id = new.customer_po_id;
    v_billed := public.customer_po_billed(new.customer_po_id);
    if v_billed + new.taxable_amount + new.advance_recovery > v_po.amount + 0.005 then
      raise exception 'This invoice would bill % on customer order % (order amount %, already billed %)',
        v_billed + new.taxable_amount + new.advance_recovery, v_po.customer_po_number, v_po.amount, v_billed using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
create trigger invoices_issue_checks before update of status on public.invoices for each row execute function public.invoices_issue_checks();

-- ---------------------------------------------------------------------------
-- Ledger postings for sales invoices (replaces the first version)
--   invoice/debit note: Dr receivables (payable), Dr retention receivable, Dr customer advances (deduction + recovery)
--                       Cr revenue (Σ line net) — or Cr customer advances for an advance invoice — Cr VAT output
--   credit note:        the opposite (an advance credit note debits customer advances instead of revenue)
-- ---------------------------------------------------------------------------

create or replace function public.post_invoice(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices%rowtype; o public.invoices%rowtype; v_lines numeric; v_income text;
begin
  select * into i from public.invoices where id = p_id;
  if i.status <> 'issued' or i.kind = 'proforma' then return; end if;
  if i.original_invoice_id is not null then select * into o from public.invoices where id = i.original_invoice_id; end if;
  v_lines := i.taxable_amount + i.advance_recovery;
  v_income := case when coalesce(o.billing_type, i.billing_type) = 'advance' then 'customer_advances' else 'revenue' end;
  if i.kind = 'credit_note' then
    perform public.post_journal_once(i.issue_date, 'invoice', i.id, 'issue', 'credit_note ' || i.number, jsonb_build_array(
      jsonb_build_object('account_key', 'receivables', 'amount', -i.total_amount, 'customer_id', i.customer_id, 'project_id', i.project_id),
      jsonb_build_object('account_key', v_income, 'amount', i.taxable_amount, 'customer_id', i.customer_id, 'project_id', i.project_id),
      jsonb_build_object('account_key', 'vat_output', 'amount', i.vat_total, 'customer_id', i.customer_id)));
  else
    perform public.post_journal_once(i.issue_date, 'invoice', i.id, 'issue', i.kind::text || ' ' || i.number, jsonb_build_array(
      jsonb_build_object('account_key', 'receivables', 'amount', i.amount_payable, 'customer_id', i.customer_id, 'project_id', i.project_id),
      jsonb_build_object('account_key', 'retention_receivable', 'amount', i.retention_amount, 'customer_id', i.customer_id, 'project_id', i.project_id),
      jsonb_build_object('account_key', 'customer_advances', 'amount', i.advance_deduction + i.advance_recovery, 'customer_id', i.customer_id, 'project_id', i.project_id),
      jsonb_build_object('account_key', v_income, 'amount', -v_lines, 'customer_id', i.customer_id, 'project_id', i.project_id),
      jsonb_build_object('account_key', 'vat_output', 'amount', -i.vat_total, 'customer_id', i.customer_id)));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Receipts: against the invoice, or collecting retention
-- ---------------------------------------------------------------------------

alter table public.customer_payments add column kind text not null default 'invoice' check (kind in ('invoice', 'retention'));

create or replace function public.customer_payments_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  inv public.invoices%rowtype;
  v_open numeric;
begin
  if tg_op = 'INSERT' then
    select * into inv from public.invoices where id = new.invoice_id for update;
    if not found or inv.status <> 'issued' or inv.kind not in ('invoice', 'debit_note') then
      raise exception 'Payments can only be recorded against issued invoices or debit notes' using errcode = 'check_violation';
    end if;
    if new.kind = 'retention' then
      v_open := inv.retention_amount - inv.retention_received;
      if new.amount > v_open then
        raise exception 'The retention still held on this invoice is %', v_open using errcode = 'check_violation';
      end if;
    else
      v_open := inv.amount_payable - inv.amount_paid - coalesce((select sum(total_amount) from public.invoices
                 where original_invoice_id = inv.id and kind = 'credit_note' and status = 'issued'), 0);
      if new.amount > v_open then
        raise exception 'The payment is more than the amount outstanding (%)', v_open using errcode = 'check_violation';
      end if;
    end if;
    new.customer_id := inv.customer_id;
    new.number := public.next_document_number('receipt', 'RCT', true, 5);
    new.voided_at := null; new.voided_by := null; new.void_reason := null;
    return new;
  end if;
  if (to_jsonb(new) - 'voided_at' - 'voided_by' - 'void_reason') <> (to_jsonb(old) - 'voided_at' - 'voided_by' - 'void_reason')
     or old.voided_at is not null or new.voided_at is null or length(trim(coalesce(new.void_reason, ''))) = 0 then
    raise exception 'A payment can only be voided once, with a reason' using errcode = 'check_violation';
  end if;
  new.voided_by := auth.uid();
  return new;
end $$;

create or replace function public.customer_payments_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('rms.invoice_paid', new.invoice_id::text, true);
  update public.invoices
     set amount_paid = (select coalesce(sum(amount), 0) from public.customer_payments where invoice_id = new.invoice_id and kind = 'invoice' and voided_at is null),
         retention_received = (select coalesce(sum(amount), 0) from public.customer_payments where invoice_id = new.invoice_id and kind = 'retention' and voided_at is null)
   where id = new.invoice_id;
  perform set_config('rms.invoice_paid', '', true);
  return null;
end $$;

create or replace function public.post_customer_payment(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p public.customer_payments%rowtype; v_proj uuid;
begin
  select * into p from public.customer_payments where id = p_id;
  select project_id into v_proj from public.invoices where id = p.invoice_id;
  perform public.post_journal_once(p.payment_date, 'customer_payment', p.id, 'payment', 'Payment ' || p.number, jsonb_build_array(
    jsonb_build_object('account', coalesce(p.bank_account_code, public.account_for('bank')), 'amount', p.amount, 'customer_id', p.customer_id, 'project_id', v_proj),
    jsonb_build_object('account_key', case when p.kind = 'retention' then 'retention_receivable' else 'receivables' end, 'amount', -p.amount,
                       'customer_id', p.customer_id, 'project_id', v_proj)));
end $$;

-- ---------------------------------------------------------------------------
-- Creating invoices from a customer order
-- ---------------------------------------------------------------------------

create or replace function public.new_order_invoice(p_po public.customer_pos, p_type text, p_title text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; c public.contracts%rowtype;
begin
  if not public.has_permission('invoices.write') then
    raise exception 'You do not have permission to prepare invoices' using errcode = 'insufficient_privilege';
  end if;
  if p_po.status not in ('accepted', 'active', 'completed') then
    raise exception 'Only accepted customer orders can be invoiced' using errcode = 'check_violation';
  end if;
  select * into c from public.contracts where id = p_po.contract_id;
  insert into public.invoices (kind, customer_id, contract_id, project_id, customer_po_id, billing_type, currency, customer_reference, title,
                               retention_pct, payment_terms_en)
  values ('invoice', p_po.customer_id, p_po.contract_id, p_po.project_id, p_po.id, p_type, p_po.currency, p_po.customer_po_number, p_title,
          case when p_type = 'advance' then 0 else coalesce(c.retention_pct, 0) end, p_po.payment_terms)
  returning id into v_id;
  if p_type = 'progress' then
    perform set_config('rms.invoice_issue', v_id::text, true);
    update public.invoices set claim_no = coalesce((select max(claim_no) from public.invoices where customer_po_id = p_po.id
                                                     and billing_type = 'progress' and status <> 'cancelled'), 0) + 1 where id = v_id;
    perform set_config('rms.invoice_issue', '', true);
  end if;
  return v_id;
end $$;
revoke all on function public.new_order_invoice(public.customer_pos, text, text) from public, anon, authenticated;

-- Advance recovery for a new claim: the contract's advance % of the claim, capped by the advance still open.
create or replace function public.apply_default_recovery(p_invoice_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices%rowtype; v_pct numeric; v_net numeric; v_rec numeric;
begin
  select * into i from public.invoices where id = p_invoice_id;
  v_pct := coalesce((select advance_payment_pct from public.contracts where id = i.contract_id), 0);
  if v_pct = 0 then return; end if;
  select coalesce(sum(net_amount), 0) into v_net from public.invoice_lines where invoice_id = p_invoice_id and vat_category = 'S';
  v_rec := least(round(v_net * v_pct / 100, 2), greatest(public.customer_advance_open(i.customer_id, i.project_id, null), 0));
  if v_rec > 0 then update public.invoices set advance_recovery = v_rec where id = p_invoice_id; end if;
end $$;
revoke all on function public.apply_default_recovery(uuid) from public, anon, authenticated;

-- Advance invoice: p_percent of the order amount (or p_amount), no retention.
create or replace function public.create_advance_invoice(p_po_id uuid, p_percent numeric, p_amount numeric default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare po public.customer_pos%rowtype; v_id uuid; v_amt numeric;
begin
  select * into po from public.customer_pos where id = p_po_id;
  if not found then raise exception 'Customer order not found' using errcode = 'no_data_found'; end if;
  v_amt := coalesce(p_amount, round(po.amount * coalesce(p_percent, 0) / 100, 2));
  if v_amt <= 0 or v_amt > po.amount then raise exception 'The advance must be more than zero and not more than the order amount' using errcode = 'check_violation'; end if;
  v_id := public.new_order_invoice(po, 'advance', 'Advance payment');
  insert into public.invoice_lines (invoice_id, sort_order, description_en, description_ar, unit, quantity, unit_price)
  values (v_id, 1, 'Advance payment' || case when p_percent is not null and p_amount is null then ' (' || trim(to_char(p_percent, 'FM990.##')) || '% of order ' || po.customer_po_number || ')' else ' on order ' || po.customer_po_number end,
          'دفعة مقدمة', 'LS', 1, v_amt);
  return v_id;
end $$;

-- Progress claim: p_lines [{po_line_id | null, cumulative_pct}] — bills (cumulative % − % already claimed) of each line
-- (null line = the whole order when it has no lines).
create or replace function public.create_progress_invoice(p_po_id uuid, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare po public.customer_pos%rowtype; v_id uuid; l jsonb; v_pct numeric; v_prev numeric; v_line public.customer_po_lines%rowtype;
        v_base numeric; v_desc text; v_amt numeric; v_n integer := 0;
begin
  select * into po from public.customer_pos where id = p_po_id;
  if not found then raise exception 'Customer order not found' using errcode = 'no_data_found'; end if;
  v_id := public.new_order_invoice(po, 'progress', null);
  for l in select * from jsonb_array_elements(p_lines) loop
    v_pct := (l ->> 'cumulative_pct')::numeric;
    continue when v_pct is null;
    if v_pct <= 0 or v_pct > 100 then raise exception 'Progress must be between 0 and 100%%' using errcode = 'check_violation'; end if;
    if nullif(l ->> 'po_line_id', '') is not null then
      select * into v_line from public.customer_po_lines where id = (l ->> 'po_line_id')::uuid and po_id = p_po_id;
      if not found then raise exception 'The item is not on this order' using errcode = 'check_violation'; end if;
      v_base := v_line.amount; v_desc := v_line.description;
    else
      if exists (select 1 from public.customer_po_lines where po_id = p_po_id) then
        raise exception 'Give the progress per item for an order with items' using errcode = 'check_violation';
      end if;
      v_line := null; v_base := po.amount; v_desc := coalesce(nullif(po.scope_notes, ''), 'Works as per order ' || po.customer_po_number);
    end if;
    select coalesce(max(il.progress_pct), 0) into v_prev from public.invoice_lines il join public.invoices i on i.id = il.invoice_id
     where i.customer_po_id = p_po_id and i.status = 'issued' and i.kind = 'invoice'
       and il.customer_po_line_id is not distinct from v_line.id and il.progress_pct is not null;
    if v_pct <= v_prev then
      raise exception '"%" was already claimed to % percent', v_desc, v_prev using errcode = 'check_violation';
    end if;
    v_amt := round(v_base * v_pct / 100, 2) - round(v_base * v_prev / 100, 2);
    v_n := v_n + 1;
    insert into public.invoice_lines (invoice_id, sort_order, description_en, unit, quantity, unit_price, customer_po_line_id, progress_pct)
    values (v_id, v_n, v_desc || ' — progress ' || trim(to_char(v_prev, 'FM990.##')) || '% → ' || trim(to_char(v_pct, 'FM990.##')) || '%',
            'LS', 1, v_amt, v_line.id, v_pct);
  end loop;
  if v_n = 0 then raise exception 'Enter the progress for at least one item' using errcode = 'check_violation'; end if;
  perform set_config('rms.invoice_issue', v_id::text, true);
  update public.invoices set title = 'Progress claim ' || (select claim_no from public.invoices where id = v_id) where id = v_id;
  perform set_config('rms.invoice_issue', '', true);
  perform public.apply_default_recovery(v_id);
  return v_id;
end $$;

-- Milestone invoice: one payment milestone of the order (percent of the order or a fixed amount).
create or replace function public.create_milestone_invoice(p_milestone_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare m public.customer_po_milestones%rowtype; po public.customer_pos%rowtype; v_id uuid; v_amt numeric;
begin
  select * into m from public.customer_po_milestones where id = p_milestone_id;
  if not found then raise exception 'Milestone not found' using errcode = 'no_data_found'; end if;
  if exists (select 1 from public.invoices where milestone_id = m.id and status <> 'cancelled') then
    raise exception 'This milestone is already invoiced' using errcode = 'check_violation';
  end if;
  select * into po from public.customer_pos where id = m.po_id;
  v_amt := coalesce(m.amount, round(po.amount * m.percent / 100, 2));
  v_id := public.new_order_invoice(po, 'milestone', m.label);
  perform set_config('rms.invoice_issue', v_id::text, true);
  update public.invoices set milestone_id = m.id where id = v_id;
  perform set_config('rms.invoice_issue', '', true);
  insert into public.invoice_lines (invoice_id, sort_order, description_en, unit, quantity, unit_price)
  values (v_id, 1, m.label || case when m.percent is not null then ' (' || trim(to_char(m.percent, 'FM990.##')) || '% of order ' || po.customer_po_number || ')' else '' end,
          'LS', 1, v_amt);
  perform public.apply_default_recovery(v_id);
  return v_id;
end $$;

create or replace function public.customer_po_milestones_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.invoices where milestone_id = coalesce(new.id, old.id) and status <> 'cancelled') then
    raise exception 'An invoiced milestone cannot change' using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end $$;
create trigger customer_po_milestones_guard before update or delete on public.customer_po_milestones
  for each row execute function public.customer_po_milestones_guard();

create trigger audit_customer_po_milestones after insert or update or delete on public.customer_po_milestones
  for each row execute function public.audit_trigger();

grant select, insert, update, delete on public.customer_po_milestones to authenticated;
grant all on public.customer_po_milestones to service_role;
revoke execute on function public.create_advance_invoice(uuid, numeric, numeric), public.create_progress_invoice(uuid, jsonb),
  public.create_milestone_invoice(uuid), public.customer_advance_open(uuid, uuid, uuid), public.customer_po_billed(uuid) from public, anon;
grant execute on function public.create_advance_invoice(uuid, numeric, numeric), public.create_progress_invoice(uuid, jsonb),
  public.create_milestone_invoice(uuid), public.customer_advance_open(uuid, uuid, uuid), public.customer_po_billed(uuid) to authenticated;

alter table public.customer_po_milestones enable row level security;
create policy customer_po_milestones_select on public.customer_po_milestones for select to authenticated
  using (public.has_permission('customer_pos.read') or public.has_permission('invoices.read'));
create policy customer_po_milestones_write on public.customer_po_milestones for all to authenticated
  using (public.has_permission('customer_pos.write') or public.has_permission('invoices.write'))
  with check (public.has_permission('customer_pos.write') or public.has_permission('invoices.write'));
