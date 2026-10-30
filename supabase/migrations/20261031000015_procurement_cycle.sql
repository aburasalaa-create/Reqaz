-- RMS full purchasing cycle:
--   requisition → procurement review (approval levels) → supplier quotations → comparison → selection (draft PO)
--   → budget check → PO approval (approval levels) → PO issued → deliveries (goods received notes, partial allowed)
--   → supplier invoice (3-way match against PO and receipts) → accounts payable → payment → closed.
--
-- Cost accounting (all amounts excluding VAT)
--   committed  = ordered but not yet received:  Σ (PO line qty − qty received) × PO unit cost, for approved/issued orders
--   actual     = posted to the project's cost accounts in the ledger: goods received (at PO cost), price differences on
--                supplier invoices, supplier invoices without a PO, approved expenses
--   Receiving moves an amount from committed to actual; invoicing a received line only clears "goods received not invoiced",
--   so nothing is counted twice. Raising a PO never changes the budget.
--
-- Postings
--   goods received:   Dr project cost (category)          Cr goods received not invoiced
--   supplier invoice: Dr goods received not invoiced (PO lines at PO cost) / Dr cost (price difference, non-PO lines)
--                     Dr VAT input                        Cr accounts payable, Cr retention payable, Cr advances to suppliers
--   payment:          Dr accounts payable | advances to suppliers | retention payable      Cr bank

-- ---------------------------------------------------------------------------
-- Requisitions: more detail and approval levels
-- ---------------------------------------------------------------------------

alter table public.purchase_requests
  add column cost_category text not null default 'materials' references public.cost_categories (code),
  add column technical_spec text,
  add column justification text,
  add column budget_check jsonb;

create or replace function public.purchase_requests_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_calc boolean := coalesce(current_setting('rms.pr_calc', true), '') = new.id::text;
        v_order boolean := coalesce(current_setting('rms.pr_order', true), '') = new.id::text;
        v_done boolean;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then raise exception 'Purchase requests start as drafts' using errcode = 'check_violation'; end if;
    new.requested_by := coalesce(auth.uid(), new.requested_by);
    new.estimated_total := 0; new.submitted_at := null; new.decided_by := null; new.decided_at := null; new.budget_check := null;
    return new;
  end if;
  if new.estimated_total is distinct from old.estimated_total and not v_calc then
    raise exception 'The estimate total is calculated from the lines' using errcode = 'insufficient_privilege';
  end if;
  if new.requested_by <> old.requested_by then
    raise exception 'The requester cannot change' using errcode = 'check_violation';
  end if;
  if new.budget_check is distinct from old.budget_check and not (old.status = 'draft' and new.status = 'submitted') then
    raise exception 'The budget check is recorded by the system' using errcode = 'insufficient_privilege';
  end if;
  if old.status not in ('draft') and (new.title, new.project_id, new.needed_by, new.delivery_location, new.notes, new.cost_category,
                                      new.technical_spec, new.justification)
       is distinct from (old.title, old.project_id, old.needed_by, old.delivery_location, old.notes, old.cost_category,
                         old.technical_spec, old.justification) then
    raise exception 'Only draft purchase requests can be edited' using errcode = 'insufficient_privilege';
  end if;
  if new.status = old.status then return new; end if;

  if old.status = 'draft' and new.status = 'submitted' then
    if not exists (select 1 from public.purchase_request_lines where request_id = new.id) then
      raise exception 'Add at least one item before submitting' using errcode = 'check_violation';
    end if;
    new.submitted_at := now();
    if new.project_id is not null then
      new.budget_check := public.budget_check(new.project_id, new.cost_category, new.estimated_total, null);
    end if;
    perform public.record_approval_event('purchase_request', new.id, 'submitted', new.estimated_total, null);
  elsif old.status = 'submitted' and new.status = 'draft' then
    if auth.uid() <> old.requested_by then
      raise exception 'Only the requester can withdraw a request' using errcode = 'insufficient_privilege';
    end if;
    new.submitted_at := null; new.budget_check := null;
    perform public.record_approval_event('purchase_request', new.id, 'returned', new.estimated_total, 'Withdrawn');
  elsif old.status = 'submitted' and new.status in ('approved', 'rejected') then
    v_done := public.decide_approval('purchase_request', new.id, new.estimated_total, old.requested_by, 'procurement.approve',
                                     new.status = 'approved', new.decision_comment);
    if new.status = 'approved' and not v_done then new.status := 'submitted'; return new; end if;
    new.decided_by := auth.uid(); new.decided_at := now();
  elsif old.status in ('draft', 'submitted', 'approved') and new.status = 'cancelled' then
    if auth.uid() <> old.requested_by and not public.has_permission('procurement.approve') then
      raise exception 'Only the requester or an approver can cancel' using errcode = 'insufficient_privilege';
    end if;
  elsif old.status = 'approved' and new.status = 'ordered' and v_order then
    null;
  else
    raise exception 'A % purchase request cannot become %', old.status, new.status using errcode = 'check_violation';
  end if;
  perform public.log_event('purchase_requests', new.id::text, old.status || ' → ' || new.status,
    case when new.decision_comment is not null then jsonb_build_object('comment', new.decision_comment) end);
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Purchase orders: approval, amendments, receipt status
-- ---------------------------------------------------------------------------

alter table public.purchase_orders alter column status drop default;
alter table public.purchase_orders alter column status type text using status::text;
alter table public.purchase_orders alter column status set default 'draft';
alter table public.purchase_orders add constraint purchase_orders_status check
  (status in ('draft', 'pending_approval', 'approved', 'issued', 'partially_received', 'received', 'closed', 'cancelled', 'superseded'));

alter table public.purchase_orders
  add column cost_category text not null default 'materials' references public.cost_categories (code),
  add column supplier_quote_id uuid,
  add column amends_id uuid references public.purchase_orders (id),
  add column root_id uuid references public.purchase_orders (id),      -- first order of an amendment chain
  add column revision_no integer not null default 0,
  add column retention_pct numeric(5, 2) not null default 0 check (retention_pct between 0 and 100),
  add column over_budget boolean not null default false,
  add column budget_check jsonb,
  add column submitted_at timestamptz,
  add column submitted_by uuid references public.app_users (id),
  add column approved_at timestamptz,
  add column approved_by uuid references public.app_users (id),
  add column decision_comment text;
update public.purchase_orders set root_id = id;
create index purchase_orders_root_idx on public.purchase_orders (root_id);
create index purchase_orders_project_idx on public.purchase_orders (project_id);

alter table public.purchase_order_lines
  add column line_ref uuid not null default gen_random_uuid(),       -- the same item across amendments
  add column request_line_id uuid references public.purchase_request_lines (id) on delete set null,
  add column cost_category text references public.cost_categories (code);
create index purchase_order_lines_ref_idx on public.purchase_order_lines (line_ref);

create or replace function public.purchase_orders_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.root_id is null then new.root_id := coalesce((select root_id from public.purchase_orders where id = new.amends_id), new.id); end if;
  return new;
end $$;
create trigger purchase_orders_defaults before insert on public.purchase_orders for each row execute function public.purchase_orders_defaults();

create or replace function public.po_lines_vat() returns trigger
language plpgsql security definer set search_path = public as $$
declare v public.vat_codes%rowtype;
begin
  select * into v from public.vat_codes where code = new.vat_code and is_active;
  if not found then raise exception 'Unknown VAT code %', new.vat_code using errcode = 'check_violation'; end if;
  new.vat_rate := v.rate; new.vat_category := v.zatca_category;
  if new.cost_category is null then new.cost_category := (select cost_category from public.purchase_orders where id = new.order_id); end if;
  return new;
end $$;
drop trigger po_lines_vat on public.purchase_order_lines;
create trigger po_lines_vat before insert or update of vat_code, cost_category on public.purchase_order_lines
  for each row execute function public.po_lines_vat();
update public.purchase_order_lines l set cost_category = o.cost_category from public.purchase_orders o where o.id = l.order_id and l.cost_category is null;

create or replace function public.po_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  select status into v_status from public.purchase_orders where id = coalesce(new.order_id, old.order_id);
  if v_status is distinct from 'draft' and coalesce(current_setting('rms.po_copy', true), '') <> coalesce(new.order_id, old.order_id)::text then
    raise exception 'Only draft purchase orders can be edited; raise an amendment' using errcode = 'insufficient_privilege';
  end if;
  if tg_op = 'UPDATE' and new.line_ref <> old.line_ref then
    raise exception 'The line reference cannot change' using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end $$;

create or replace function public.purchase_orders_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_calc boolean := coalesce(current_setting('rms.po_calc', true), '') = new.id::text;
        v_issue boolean := coalesce(current_setting('rms.po_issue', true), '') = new.id::text;
        v_done boolean;
        v_keys text[] := array['status', 'status_changed_at', 'cancel_reason', 'pdf_attachment_id', 'updated_at', 'decision_comment',
                               'submitted_at', 'submitted_by', 'approved_at', 'approved_by', 'over_budget', 'budget_check'];
begin
  if tg_op = 'INSERT' then
    if (new.status <> 'draft' or new.number is not null) and not v_issue then
      raise exception 'Purchase orders are created as drafts' using errcode = 'check_violation';
    end if;
    new.subtotal := 0; new.discount_total := 0; new.taxable_amount := 0; new.vat_total := 0; new.total_amount := 0;
    new.issued_at := null; new.issued_by := null; new.supplier_snapshot := null; new.buyer_snapshot := null;
    new.submitted_at := null; new.submitted_by := null; new.approved_at := null; new.approved_by := null; new.over_budget := false; new.budget_check := null;
    return new;
  end if;
  if v_issue then return new; end if;
  -- Approvers who do not buy can only approve or reject an order waiting for them.
  if not v_calc and not public.has_permission('procurement.order')
     and coalesce(current_setting('rms.po_receipt', true), '') <> new.id::text
     and coalesce(current_setting('rms.po_supersede', true), '') <> new.id::text
     and not (old.status = 'pending_approval' and new.status in ('approved', 'draft')) then
    raise exception 'You do not have permission to change purchase orders' using errcode = 'insufficient_privilege';
  end if;
  if not v_calc and (new.subtotal, new.discount_total, new.taxable_amount, new.vat_total, new.total_amount)
       is distinct from (old.subtotal, old.discount_total, old.taxable_amount, old.vat_total, old.total_amount) then
    raise exception 'Order totals are calculated by the system' using errcode = 'insufficient_privilege';
  end if;
  if (new.number, new.issued_at, new.issue_date, new.issued_by, new.supplier_snapshot, new.buyer_snapshot, new.purchase_request_id,
      new.amends_id, new.root_id, new.revision_no, new.supplier_quote_id)
       is distinct from (old.number, old.issued_at, old.issue_date, old.issued_by, old.supplier_snapshot, old.buyer_snapshot, old.purchase_request_id,
      old.amends_id, old.root_id, old.revision_no, old.supplier_quote_id) then
    raise exception 'Issue details are set by the system' using errcode = 'insufficient_privilege';
  end if;
  if (new.over_budget, new.budget_check, new.submitted_at, new.submitted_by, new.approved_at, new.approved_by)
       is distinct from (old.over_budget, old.budget_check, old.submitted_at, old.submitted_by, old.approved_at, old.approved_by)
     and new.status = old.status then
    raise exception 'Approval details are set by the workflow' using errcode = 'insufficient_privilege';
  end if;
  if old.status <> 'draft' then
    if (to_jsonb(new) - v_keys) <> (to_jsonb(old) - v_keys)
       or (old.pdf_attachment_id is not null and new.pdf_attachment_id is distinct from old.pdf_attachment_id) then
      raise exception 'A purchase order cannot be changed after it is submitted; return it to draft or raise an amendment'
        using errcode = 'insufficient_privilege';
    end if;
  end if;
  if new.status = old.status then return new; end if;

  if old.status = 'draft' and new.status = 'pending_approval' then
    if not public.has_permission('procurement.order') then
      raise exception 'You do not have permission to submit purchase orders' using errcode = 'insufficient_privilege';
    end if;
    if not exists (select 1 from public.purchase_order_lines where order_id = new.id) or new.total_amount <= 0 then
      raise exception 'Add at least one priced line before submitting' using errcode = 'check_violation';
    end if;
    new.submitted_at := now(); new.submitted_by := auth.uid();
    if new.project_id is not null then
      new.budget_check := public.po_budget_check(new.id);
      new.over_budget := coalesce((new.budget_check ->> 'over_budget')::boolean, false);
    else
      new.budget_check := null; new.over_budget := false;
    end if;
    perform public.record_approval_event('purchase_order', new.id, 'submitted', new.taxable_amount, null);
  elsif old.status = 'pending_approval' and new.status = 'draft' then
    -- Withdrawn by the buyer, or rejected by an approver (with a reason).
    if public.has_permission('procurement.approve') and auth.uid() is distinct from old.submitted_by then
      perform public.decide_approval('purchase_order', new.id, new.taxable_amount, old.submitted_by, 'procurement.approve', false, new.decision_comment);
    else
      perform public.record_approval_event('purchase_order', new.id, 'returned', new.taxable_amount, coalesce(new.decision_comment, 'Withdrawn'));
    end if;
    new.submitted_at := null; new.submitted_by := null;
  elsif old.status = 'pending_approval' and new.status = 'approved' then
    if old.over_budget and length(trim(coalesce(new.decision_comment, ''))) = 0 then
      raise exception 'This order goes over the project budget; add a comment to approve it' using errcode = 'check_violation';
    end if;
    v_done := public.decide_approval('purchase_order', new.id, new.taxable_amount, coalesce(old.submitted_by, old.created_by),
                                     'procurement.approve', true, new.decision_comment);
    if not v_done then new.status := 'pending_approval'; return new; end if;
    new.approved_at := now(); new.approved_by := auth.uid();
  elsif new.status = 'issued' then
    raise exception 'Use the issue action' using errcode = 'insufficient_privilege';
  elsif new.status in ('partially_received', 'received') and coalesce(current_setting('rms.po_receipt', true), '') = new.id::text then
    null;
  elsif old.status in ('issued', 'partially_received', 'received') and new.status = 'closed' then
    if not public.has_permission('procurement.order') then
      raise exception 'You do not have permission to close purchase orders' using errcode = 'insufficient_privilege';
    end if;
    if exists (select 1 from public.supplier_invoices where po_id = new.id and status = 'draft') then
      raise exception 'Post or cancel the draft supplier invoices for this order first' using errcode = 'check_violation';
    end if;
  elsif old.status in ('draft', 'pending_approval', 'approved', 'issued') and new.status = 'cancelled' then
    if length(trim(coalesce(new.cancel_reason, ''))) = 0 then
      raise exception 'A reason is required to cancel a purchase order' using errcode = 'check_violation';
    end if;
    -- Receipts belong to the issued version; an amendment that was never issued can still be cancelled.
    if old.status = 'issued' and exists (select 1 from public.purchase_order_lines l where l.order_id = new.id and public.po_line_received(l.line_ref) > 0) then
      raise exception 'Goods have been received on this order; close it instead of cancelling' using errcode = 'check_violation';
    end if;
  elsif old.status in ('issued', 'partially_received', 'received') and new.status = 'superseded' and coalesce(current_setting('rms.po_supersede', true), '') = new.id::text then
    null;
  else
    raise exception 'A % purchase order cannot become %', replace(old.status, '_', ' '), replace(new.status, '_', ' ') using errcode = 'check_violation';
  end if;
  new.status_changed_at := now();
  perform public.log_event('purchase_orders', new.id::text, old.status || ' → ' || new.status,
    case when coalesce(new.cancel_reason, new.decision_comment) is not null
         then jsonb_build_object('comment', coalesce(new.cancel_reason, new.decision_comment)) end);
  return new;
end $$;

drop policy purchase_orders_update on public.purchase_orders;
create policy purchase_orders_update on public.purchase_orders for update to authenticated
  using (public.has_permission('procurement.order') or public.has_permission('procurement.approve'))
  with check (public.has_permission('procurement.order') or public.has_permission('procurement.approve'));

-- Issue an approved order: next gap-free PO number (amendments keep the number with -A1, -A2 ...), supplier details frozen.
create or replace function public.issue_purchase_order(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare po public.purchase_orders%rowtype; su public.suppliers%rowtype; co public.company_settings%rowtype; v_now timestamptz := now();
        v_number text; prev public.purchase_orders%rowtype; l record;
begin
  if not public.has_permission('procurement.order') then
    raise exception 'You do not have permission to issue purchase orders' using errcode = 'insufficient_privilege';
  end if;
  select * into po from public.purchase_orders where id = p_id for update;
  if not found then raise exception 'Purchase order not found' using errcode = 'no_data_found'; end if;
  if po.status <> 'approved' then
    raise exception 'The purchase order must be approved before it is issued (it is %)', replace(po.status, '_', ' ') using errcode = 'check_violation';
  end if;
  select * into su from public.suppliers where id = po.supplier_id;
  if not su.is_active then raise exception 'The supplier is inactive' using errcode = 'check_violation'; end if;
  select * into co from public.company_settings;
  if po.amends_id is not null then
    select * into prev from public.purchase_orders where id = po.amends_id for update;
    if prev.status not in ('issued', 'partially_received', 'received') then
      raise exception 'The order being amended is %', prev.status using errcode = 'check_violation';
    end if;
    for l in select l2.line_ref, sum(l2.quantity) as qty from public.purchase_order_lines l2 where l2.order_id = prev.id group by 1 loop
      if public.po_line_received(l.line_ref) > coalesce((select sum(quantity) from public.purchase_order_lines where order_id = p_id and line_ref = l.line_ref), 0) then
        raise exception 'An amended quantity is below what has already been received' using errcode = 'check_violation';
      end if;
    end loop;
    v_number := split_part(prev.number, '-A', 1) || '-A' || po.revision_no;
  else
    v_number := public.next_document_number('purchase_order', 'PO', true, 5);
  end if;
  perform set_config('rms.po_issue', p_id::text, true);
  update public.purchase_orders
     set status = 'issued', number = v_number,
         issued_at = v_now, issue_date = (v_now at time zone 'Asia/Riyadh')::date, issued_by = auth.uid(), status_changed_at = v_now,
         supplier_snapshot = to_jsonb(su) - 'notes' - 'created_by' - 'created_at' - 'updated_at',
         buyer_snapshot = to_jsonb(co) - 'id' - 'updated_at' - 'allow_self_approval' - 'quotation_validity_days' - 'bank_accounts'
                          - 'open_access' - 'segregation_of_duties'
   where id = p_id;
  perform set_config('rms.po_issue', '', true);
  if po.amends_id is not null then
    perform set_config('rms.po_supersede', po.amends_id::text, true);
    update public.purchase_orders set status = 'superseded' where id = po.amends_id;
    perform set_config('rms.po_supersede', '', true);
    perform public.refresh_po_receipt_status(p_id);
  end if;
  perform public.log_event('purchase_orders', p_id::text, 'issued', jsonb_build_object('number', v_number));
end $$;

-- Start an amendment: a draft copy of an issued order (same items and line references). Issuing it replaces the original.
create or replace function public.amend_purchase_order(p_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare po public.purchase_orders%rowtype; v_id uuid;
begin
  if not public.has_permission('procurement.order') then
    raise exception 'You do not have permission to amend purchase orders' using errcode = 'insufficient_privilege';
  end if;
  select * into po from public.purchase_orders where id = p_id for update;
  if po.status not in ('issued', 'partially_received', 'received') then
    raise exception 'Only an issued order can be amended' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.purchase_orders where amends_id = p_id and status not in ('cancelled')) then
    raise exception 'This order already has an amendment in progress' using errcode = 'check_violation';
  end if;
  insert into public.purchase_orders (supplier_id, project_id, currency, supplier_quote_ref, delivery_date, delivery_address, payment_terms,
                                      terms, notes, cost_category, retention_pct, amends_id, root_id)
  values (po.supplier_id, po.project_id, po.currency, po.supplier_quote_ref, po.delivery_date, po.delivery_address, po.payment_terms,
          po.terms, po.notes, po.cost_category, po.retention_pct, po.id, po.root_id)
  returning id into v_id;
  perform set_config('rms.po_issue', v_id::text, true);
  update public.purchase_orders set revision_no = po.revision_no + 1, purchase_request_id = po.purchase_request_id,
         supplier_quote_id = po.supplier_quote_id where id = v_id;
  perform set_config('rms.po_issue', '', true);
  insert into public.purchase_order_lines (order_id, sort_order, item_code, description, unit, quantity, unit_price, discount_amount, vat_code,
                                           line_ref, request_line_id, cost_category)
  select v_id, sort_order, item_code, description, unit, quantity, unit_price, discount_amount, vat_code, line_ref, request_line_id, cost_category
    from public.purchase_order_lines where order_id = p_id;
  perform public.log_event('purchase_orders', p_id::text, 'amendment started', jsonb_build_object('amendment_id', v_id));
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Supplier quotations and comparison
-- ---------------------------------------------------------------------------

create table public.supplier_quotes (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  request_id uuid not null references public.purchase_requests (id) on delete restrict,
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  quote_ref text,
  quote_date date not null default (now() at time zone 'Asia/Riyadh')::date,
  valid_until date,
  delivery_days integer check (delivery_days >= 0),
  delivery_terms text,
  payment_terms text,
  warranty text,
  technical_compliance text not null default 'compliant' check (technical_compliance in ('compliant', 'partial', 'non_compliant')),
  commercial_notes text,
  currency char(3) not null default 'SAR' references public.currencies (code),
  subtotal numeric(18, 2) not null default 0,
  vat_total numeric(18, 2) not null default 0,
  total_amount numeric(18, 2) not null default 0,
  status text not null default 'received' check (status in ('received', 'selected', 'not_selected')),
  selection_reason text,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (request_id, supplier_id)
);
create trigger supplier_quotes_updated before update on public.supplier_quotes for each row execute function public.set_updated_at();
alter table public.purchase_orders add constraint purchase_orders_quote_fk foreign key (supplier_quote_id) references public.supplier_quotes (id);

create table public.supplier_quote_lines (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.supplier_quotes (id) on delete cascade,
  request_line_id uuid not null references public.purchase_request_lines (id) on delete restrict,
  quantity numeric(18, 3) not null check (quantity > 0),
  unit_price numeric(18, 4) not null check (unit_price >= 0),
  vat_code text not null default 'S15' references public.vat_codes (code),
  vat_rate numeric(5, 2) not null default 15,
  vat_category char(1) not null default 'S',
  net_amount numeric(18, 2) generated always as (round(quantity * unit_price, 2)) stored,
  notes text,
  unique (quote_id, request_line_id)
);

create or replace function public.supplier_quotes_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_pr text;
begin
  select status into v_pr from public.purchase_requests where id = coalesce(new.request_id, old.request_id);
  if tg_op = 'INSERT' then
    if v_pr <> 'approved' then raise exception 'Supplier quotations are recorded after the request is approved' using errcode = 'check_violation'; end if;
    new.number := public.next_document_number('supplier_quote', 'SQ', true, 5);
    new.status := 'received'; new.subtotal := 0; new.vat_total := 0; new.total_amount := 0;
    return new;
  end if;
  if new.request_id <> old.request_id or new.supplier_id <> old.supplier_id or new.number <> old.number then
    raise exception 'The request and supplier cannot change' using errcode = 'check_violation';
  end if;
  if coalesce(current_setting('rms.sq_calc', true), '') = new.id::text then return new; end if;
  if (new.subtotal, new.vat_total, new.total_amount) is distinct from (old.subtotal, old.vat_total, old.total_amount) then
    raise exception 'Quotation totals are calculated from the lines' using errcode = 'insufficient_privilege';
  end if;
  if (old.status <> 'received' or v_pr <> 'approved') and coalesce(current_setting('rms.sq_select', true), '') <> new.request_id::text then
    raise exception 'The comparison is closed; this quotation can no longer change' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger supplier_quotes_before before insert or update on public.supplier_quotes for each row execute function public.supplier_quotes_before();

create or replace function public.supplier_quote_lines_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare q public.supplier_quotes%rowtype; v public.vat_codes%rowtype;
begin
  select * into q from public.supplier_quotes where id = coalesce(new.quote_id, old.quote_id);
  if q.status <> 'received' or (select status from public.purchase_requests where id = q.request_id) <> 'approved' then
    raise exception 'The comparison is closed; this quotation can no longer change' using errcode = 'insufficient_privilege';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if (select request_id from public.purchase_request_lines where id = new.request_line_id) <> q.request_id then
    raise exception 'The item is not on this purchase request' using errcode = 'check_violation';
  end if;
  select * into v from public.vat_codes where code = new.vat_code and is_active;
  if not found then raise exception 'Unknown VAT code %', new.vat_code using errcode = 'check_violation'; end if;
  new.vat_rate := v.rate; new.vat_category := v.zatca_category;
  return new;
end $$;
create trigger supplier_quote_lines_before before insert or update or delete on public.supplier_quote_lines
  for each row execute function public.supplier_quote_lines_before();

create or replace function public.supplier_quote_lines_total() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce(new.quote_id, old.quote_id); v_net numeric; v_vat numeric;
begin
  select coalesce(sum(net_amount), 0) into v_net from public.supplier_quote_lines where quote_id = v_id;
  select coalesce(sum(c), 0) into v_vat from (select round(sum(net_amount) * vat_rate / 100, 2) as c
    from public.supplier_quote_lines where quote_id = v_id group by vat_category, vat_rate) x;
  perform set_config('rms.sq_calc', v_id::text, true);
  update public.supplier_quotes set subtotal = v_net, vat_total = v_vat, total_amount = v_net + v_vat where id = v_id;
  perform set_config('rms.sq_calc', '', true);
  return null;
end $$;
create trigger supplier_quote_lines_total after insert or update or delete on public.supplier_quote_lines
  for each row execute function public.supplier_quote_lines_total();

-- Pick the winning quotation: creates the draft purchase order with its prices and terms and closes the comparison.
-- Choosing anything but the lowest compliant total needs a reason.
create or replace function public.select_supplier_quote(p_quote_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare q public.supplier_quotes%rowtype; r public.purchase_requests%rowtype; v_id uuid; v_lowest uuid;
begin
  if not public.has_permission('procurement.order') then
    raise exception 'You do not have permission to create purchase orders' using errcode = 'insufficient_privilege';
  end if;
  select * into q from public.supplier_quotes where id = p_quote_id for update;
  if not found then raise exception 'Supplier quotation not found' using errcode = 'no_data_found'; end if;
  select * into r from public.purchase_requests where id = q.request_id for update;
  if r.status <> 'approved' then raise exception 'Only approved purchase requests can be ordered' using errcode = 'check_violation'; end if;
  if not exists (select 1 from public.supplier_quote_lines where quote_id = q.id) then
    raise exception 'The quotation has no prices' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.suppliers where id = q.supplier_id and is_active) then
    raise exception 'The supplier is inactive' using errcode = 'check_violation';
  end if;
  select id into v_lowest from public.supplier_quotes where request_id = r.id and technical_compliance <> 'non_compliant'
     and exists (select 1 from public.supplier_quote_lines where quote_id = supplier_quotes.id)
   order by total_amount, quote_date limit 1;
  if v_lowest is distinct from q.id and length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'This is not the lowest compliant quotation; give the reason for choosing it' using errcode = 'check_violation';
  end if;

  insert into public.purchase_orders (supplier_id, project_id, delivery_date, delivery_address, payment_terms, cost_category, supplier_quote_ref,
                                      terms, notes)
  values (q.supplier_id, r.project_id, coalesce(r.needed_by, q.quote_date + coalesce(q.delivery_days, 0)), r.delivery_location,
          q.payment_terms, r.cost_category, q.quote_ref,
          nullif(concat_ws(E'\n', case when q.delivery_terms is not null then 'Delivery: ' || q.delivery_terms end,
                           case when q.warranty is not null then 'Warranty: ' || q.warranty end), ''),
          r.technical_spec)
  returning id into v_id;
  perform set_config('rms.po_issue', v_id::text, true);
  update public.purchase_orders set purchase_request_id = r.id, supplier_quote_id = q.id where id = v_id;
  perform set_config('rms.po_issue', '', true);
  insert into public.purchase_order_lines (order_id, sort_order, description, unit, quantity, unit_price, vat_code, request_line_id, cost_category)
  select v_id, rl.sort_order, rl.description, rl.unit, ql.quantity, ql.unit_price, ql.vat_code, rl.id, r.cost_category
    from public.supplier_quote_lines ql join public.purchase_request_lines rl on rl.id = ql.request_line_id
   where ql.quote_id = q.id;

  perform set_config('rms.sq_select', r.id::text, true);
  update public.supplier_quotes set status = case when id = q.id then 'selected' else 'not_selected' end,
         selection_reason = case when id = q.id then nullif(trim(coalesce(p_reason, '')), '') else selection_reason end
   where request_id = r.id;
  perform set_config('rms.sq_select', '', true);
  perform set_config('rms.pr_order', r.id::text, true);
  update public.purchase_requests set status = 'ordered' where id = r.id;
  perform set_config('rms.pr_order', '', true);
  perform public.log_event('purchase_requests', r.id::text, 'supplier selected',
    jsonb_build_object('quote_id', q.id, 'supplier_id', q.supplier_id, 'purchase_order_id', v_id, 'reason', p_reason));
  return v_id;
end $$;

-- Ordering straight from an approved request (no quotations): same as before, now also copying the cost category.
create or replace function public.order_from_request(p_request_id uuid, p_supplier_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.purchase_requests%rowtype; v_id uuid;
begin
  if not public.has_permission('procurement.order') then
    raise exception 'You do not have permission to create purchase orders' using errcode = 'insufficient_privilege';
  end if;
  select * into r from public.purchase_requests where id = p_request_id for update;
  if not found then raise exception 'Purchase request not found' using errcode = 'no_data_found'; end if;
  if r.status <> 'approved' then raise exception 'Only approved purchase requests can be ordered' using errcode = 'check_violation'; end if;
  if not exists (select 1 from public.suppliers where id = p_supplier_id and is_active) then
    raise exception 'Choose an active supplier' using errcode = 'check_violation';
  end if;
  insert into public.purchase_orders (supplier_id, project_id, delivery_date, delivery_address, cost_category, notes)
  values (p_supplier_id, r.project_id, r.needed_by, r.delivery_location, r.cost_category, r.technical_spec) returning id into v_id;
  perform set_config('rms.po_issue', v_id::text, true);
  update public.purchase_orders set purchase_request_id = r.id where id = v_id;
  perform set_config('rms.po_issue', '', true);
  insert into public.purchase_order_lines (order_id, sort_order, description, unit, quantity, unit_price, request_line_id, cost_category)
  select v_id, sort_order, description, unit, quantity, estimated_unit_cost, id, r.cost_category from public.purchase_request_lines where request_id = r.id;
  if exists (select 1 from public.supplier_quotes where request_id = r.id) then
    perform set_config('rms.sq_select', r.id::text, true);
    update public.supplier_quotes set status = 'not_selected' where request_id = r.id;
    perform set_config('rms.sq_select', '', true);
  end if;
  perform set_config('rms.pr_order', r.id::text, true);
  update public.purchase_requests set status = 'ordered' where id = r.id;
  perform set_config('rms.pr_order', '', true);
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Goods received notes (deliveries; also used to certify services and subcontract work)
-- ---------------------------------------------------------------------------

create table public.goods_receipts (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  po_id uuid not null references public.purchase_orders (id) on delete restrict,
  receipt_date date not null default (now() at time zone 'Asia/Riyadh')::date,
  delivery_note_ref text,
  notes text,
  status text not null default 'posted' check (status in ('posted', 'cancelled')),
  received_by uuid references public.app_users (id) default auth.uid(),
  cancelled_at timestamptz,
  cancel_reason text,
  created_at timestamptz not null default now()
);
create index goods_receipts_po_idx on public.goods_receipts (po_id);

create table public.goods_receipt_lines (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.goods_receipts (id) on delete restrict,
  po_line_id uuid not null references public.purchase_order_lines (id) on delete restrict,
  line_ref uuid not null,
  quantity numeric(18, 3) not null check (quantity > 0),
  unit_cost numeric(18, 6) not null,         -- PO net unit cost at receipt
  amount numeric(18, 2) not null,             -- valued at PO cost, excl. VAT
  notes text
);
create index goods_receipt_lines_ref_idx on public.goods_receipt_lines (line_ref);

create or replace function public.refresh_po_receipt_status(p_po_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_status text; v_any boolean; v_all boolean;
begin
  select status into v_status from public.purchase_orders where id = p_po_id;
  if v_status not in ('issued', 'partially_received', 'received') then return; end if;
  select bool_or(public.po_line_received(line_ref) > 0), bool_and(public.po_line_received(line_ref) >= quantity)
    into v_any, v_all from public.purchase_order_lines where order_id = p_po_id;
  perform set_config('rms.po_receipt', p_po_id::text, true);
  update public.purchase_orders set status = case when v_all then 'received' when v_any then 'partially_received' else 'issued' end
   where id = p_po_id and status <> case when v_all then 'received' when v_any then 'partially_received' else 'issued' end;
  perform set_config('rms.po_receipt', '', true);
end $$;

-- Record a delivery. p_lines: [{po_line_id, quantity, notes}]. Quantities cannot exceed what is still to come.
create or replace function public.receive_goods(p_po_id uuid, p_date date, p_delivery_note text, p_notes text, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare po public.purchase_orders%rowtype; v_id uuid; l jsonb; pl public.purchase_order_lines%rowtype; v_qty numeric; v_unit numeric;
        v_amt numeric; v_journal jsonb := '[]'::jsonb; v_total numeric := 0;
begin
  if not (public.has_permission('procurement.request') or public.has_permission('procurement.order')) then
    raise exception 'You do not have permission to receive goods' using errcode = 'insufficient_privilege';
  end if;
  select * into po from public.purchase_orders where id = p_po_id for update;
  if not found then raise exception 'Purchase order not found' using errcode = 'no_data_found'; end if;
  if po.status not in ('issued', 'partially_received') then
    raise exception 'Goods can only be received on an issued order (this one is %)', replace(po.status, '_', ' ') using errcode = 'check_violation';
  end if;
  insert into public.goods_receipts (number, po_id, receipt_date, delivery_note_ref, notes)
  values (public.next_document_number('goods_receipt', 'GRN', true, 5), p_po_id, coalesce(p_date, (now() at time zone 'Asia/Riyadh')::date),
          nullif(trim(coalesce(p_delivery_note, '')), ''), p_notes)
  returning id into v_id;
  for l in select * from jsonb_array_elements(p_lines) loop
    v_qty := round(coalesce((l ->> 'quantity')::numeric, 0), 3);
    continue when v_qty = 0;
    if v_qty < 0 then raise exception 'Quantities received must be positive' using errcode = 'check_violation'; end if;
    select * into pl from public.purchase_order_lines where id = (l ->> 'po_line_id')::uuid and order_id = p_po_id;
    if not found then raise exception 'The item is not on this purchase order' using errcode = 'check_violation'; end if;
    if public.po_line_received(pl.line_ref) + v_qty > pl.quantity then
      raise exception 'Only % % of "%" are still to be received', pl.quantity - public.po_line_received(pl.line_ref), pl.unit, pl.description
        using errcode = 'check_violation';
    end if;
    v_unit := pl.net_amount / pl.quantity;
    v_amt := round(v_qty * v_unit, 2);
    insert into public.goods_receipt_lines (receipt_id, po_line_id, line_ref, quantity, unit_cost, amount, notes)
    values (v_id, pl.id, pl.line_ref, v_qty, v_unit, v_amt, l ->> 'notes');
    v_journal := v_journal || jsonb_build_array(jsonb_build_object('account', public.cost_account(coalesce(pl.cost_category, po.cost_category), po.project_id),
      'amount', v_amt, 'project_id', po.project_id, 'supplier_id', po.supplier_id,
      'cost_category', case when po.project_id is not null then coalesce(pl.cost_category, po.cost_category) end, 'description', pl.description));
    v_total := v_total + v_amt;
  end loop;
  if v_total = 0 and not exists (select 1 from public.goods_receipt_lines where receipt_id = v_id) then
    raise exception 'Enter the quantity received for at least one item' using errcode = 'check_violation';
  end if;
  v_journal := v_journal || jsonb_build_array(jsonb_build_object('account_key', 'grni', 'amount', -v_total, 'supplier_id', po.supplier_id, 'project_id', po.project_id));
  perform public.post_journal(coalesce(p_date, (now() at time zone 'Asia/Riyadh')::date), 'goods_receipt', v_id, 'receive',
                              'Goods received on ' || po.number, v_journal);
  perform public.refresh_po_receipt_status(p_po_id);
  perform public.log_event('goods_receipts', v_id::text, 'received', jsonb_build_object('po_id', p_po_id));
  return v_id;
end $$;

create or replace function public.cancel_goods_receipt(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare g public.goods_receipts%rowtype; l record;
begin
  if not public.has_permission('procurement.order') then
    raise exception 'You do not have permission to cancel receipts' using errcode = 'insufficient_privilege';
  end if;
  select * into g from public.goods_receipts where id = p_id for update;
  if g.status <> 'posted' then raise exception 'This receipt is already cancelled' using errcode = 'check_violation'; end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'A reason is required' using errcode = 'check_violation'; end if;
  for l in select line_ref, sum(quantity) as qty from public.goods_receipt_lines where receipt_id = p_id group by 1 loop
    if public.po_line_received(l.line_ref) - l.qty < public.po_line_invoiced(l.line_ref) then
      raise exception 'Items on this receipt are already invoiced by the supplier' using errcode = 'check_violation';
    end if;
  end loop;
  perform set_config('rms.grn_cancel', p_id::text, true);
  update public.goods_receipts set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason where id = p_id;
  perform set_config('rms.grn_cancel', '', true);
  perform public.reverse_source('goods_receipt', p_id, null, (now() at time zone 'Asia/Riyadh')::date, 'Receipt cancelled: ' || p_reason);
  perform public.refresh_po_receipt_status(g.po_id);
end $$;

create or replace function public.goods_receipts_guard() returns trigger
language plpgsql as $$
begin
  if tg_table_name = 'goods_receipts' and tg_op = 'UPDATE' and coalesce(current_setting('rms.grn_cancel', true), '') = old.id::text then
    return new;
  end if;
  raise exception 'Goods received notes cannot be changed; cancel and record again' using errcode = 'insufficient_privilege';
end $$;
create trigger goods_receipts_guard before update or delete on public.goods_receipts for each row execute function public.goods_receipts_guard();
create trigger goods_receipt_lines_guard before update or delete on public.goods_receipt_lines for each row execute function public.goods_receipts_guard();

-- ---------------------------------------------------------------------------
-- Supplier invoices (bills) and 3-way matching
-- ---------------------------------------------------------------------------

create table public.supplier_invoices (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,                          -- internal BILL-YYYY-NNNNN
  supplier_invoice_number text not null check (length(trim(supplier_invoice_number)) > 0),
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  po_id uuid references public.purchase_orders (id) on delete restrict,
  project_id uuid references public.projects (id) on delete restrict,
  cost_category text references public.cost_categories (code),   -- for lines without a PO
  invoice_date date not null,
  due_date date,
  currency char(3) not null default 'SAR' references public.currencies (code),
  subtotal numeric(18, 2) not null default 0,           -- excl. VAT
  vat_total numeric(18, 2) not null default 0,
  total_amount numeric(18, 2) not null default 0,
  retention_pct numeric(5, 2) not null default 0 check (retention_pct between 0 and 100),
  retention_amount numeric(18, 2) not null default 0,
  advance_recovery numeric(18, 2) not null default 0 check (advance_recovery >= 0),
  amount_payable numeric(18, 2) not null default 0,     -- total − retention − advance recovered
  amount_paid numeric(18, 2) not null default 0,
  retention_released numeric(18, 2) not null default 0,
  status text not null default 'draft' check (status in ('draft', 'posted', 'cancelled')),
  match_status text check (match_status in ('matched', 'variance', 'no_po')),
  match_details jsonb,
  override_comment text,
  notes text,
  posted_at timestamptz,
  posted_by uuid references public.app_users (id),
  cancelled_at timestamptz,
  cancel_reason text,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint supplier_invoices_unique unique (supplier_id, supplier_invoice_number)
);
create index supplier_invoices_po_idx on public.supplier_invoices (po_id);
create index supplier_invoices_project_idx on public.supplier_invoices (project_id);
create trigger supplier_invoices_updated before update on public.supplier_invoices for each row execute function public.set_updated_at();

create table public.supplier_invoice_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.supplier_invoices (id) on delete cascade,
  sort_order integer not null default 0,
  po_line_id uuid references public.purchase_order_lines (id) on delete restrict,
  line_ref uuid,
  description text not null check (length(trim(description)) > 0),
  unit text not null default 'EA',
  quantity numeric(18, 3) not null check (quantity > 0),
  unit_price numeric(18, 4) not null check (unit_price >= 0),
  vat_code text not null default 'S15' references public.vat_codes (code),
  vat_rate numeric(5, 2) not null default 15,
  vat_category char(1) not null default 'S',
  cost_category text references public.cost_categories (code),
  net_amount numeric(18, 2) generated always as (round(quantity * unit_price, 2)) stored,
  created_at timestamptz not null default now()
);
create index supplier_invoice_lines_ref_idx on public.supplier_invoice_lines (line_ref);

-- Quantities received / invoiced so far for an item (all orders of the amendment chain).
create or replace function public.po_line_received(p_line_ref uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(gl.quantity), 0) from public.goods_receipt_lines gl join public.goods_receipts g on g.id = gl.receipt_id
   where gl.line_ref = p_line_ref and g.status = 'posted'
$$;

create or replace function public.po_line_invoiced(p_line_ref uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(sl.quantity), 0) from public.supplier_invoice_lines sl join public.supplier_invoices s on s.id = sl.invoice_id
   where sl.line_ref = p_line_ref and s.status = 'posted'
$$;

create or replace function public.supplier_invoices_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare po public.purchase_orders%rowtype;
begin
  new.number := public.next_document_number('supplier_invoice', 'BILL', true, 5);
  if new.status <> 'draft' then raise exception 'Supplier invoices are entered as drafts' using errcode = 'check_violation'; end if;
  if new.po_id is not null then
    select * into po from public.purchase_orders where id = new.po_id;
    if po.status not in ('issued', 'partially_received', 'received', 'closed') then
      raise exception 'The purchase order is % and cannot be invoiced', replace(po.status, '_', ' ') using errcode = 'check_violation';
    end if;
    new.supplier_id := po.supplier_id; new.project_id := po.project_id;
    new.retention_pct := case when new.retention_pct = 0 then po.retention_pct else new.retention_pct end;
    new.cost_category := coalesce(new.cost_category, po.cost_category);
  end if;
  new.subtotal := 0; new.vat_total := 0; new.total_amount := 0; new.retention_amount := 0; new.amount_payable := 0;
  new.amount_paid := 0; new.retention_released := 0; new.posted_at := null; new.posted_by := null; new.match_status := null; new.match_details := null;
  return new;
end $$;
create trigger supplier_invoices_before_insert before insert on public.supplier_invoices for each row execute function public.supplier_invoices_before_insert();

create or replace function public.recalculate_supplier_invoice(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s public.supplier_invoices%rowtype; v_net numeric; v_vat numeric; v_ret numeric;
begin
  select * into s from public.supplier_invoices where id = p_id;
  if s.status <> 'draft' then return; end if;
  select coalesce(sum(net_amount), 0) into v_net from public.supplier_invoice_lines where invoice_id = p_id;
  select coalesce(sum(c), 0) into v_vat from (select round(sum(net_amount) * vat_rate / 100, 2) as c
    from public.supplier_invoice_lines where invoice_id = p_id group by vat_category, vat_rate) x;
  v_ret := round(v_net * s.retention_pct / 100, 2);
  perform set_config('rms.bill_calc', p_id::text, true);
  update public.supplier_invoices set subtotal = v_net, vat_total = v_vat, total_amount = v_net + v_vat, retention_amount = v_ret,
         amount_payable = v_net + v_vat - v_ret - s.advance_recovery where id = p_id;
  perform set_config('rms.bill_calc', '', true);
end $$;

create or replace function public.supplier_invoice_lines_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.supplier_invoices%rowtype; pl public.purchase_order_lines%rowtype; v public.vat_codes%rowtype;
begin
  select * into s from public.supplier_invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if s.status <> 'draft' then
    raise exception 'Only draft supplier invoices can be edited' using errcode = 'insufficient_privilege';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  if new.po_line_id is not null then
    select * into pl from public.purchase_order_lines where id = new.po_line_id;
    if s.po_id is null or pl.line_ref not in (select line_ref from public.purchase_order_lines where order_id = s.po_id) then
      raise exception 'The item is not on this invoice''s purchase order' using errcode = 'check_violation';
    end if;
    new.line_ref := pl.line_ref; new.cost_category := coalesce(pl.cost_category, s.cost_category);
  else
    new.line_ref := null; new.cost_category := coalesce(new.cost_category, s.cost_category, 'other');
  end if;
  select * into v from public.vat_codes where code = new.vat_code and is_active;
  if not found then raise exception 'Unknown VAT code %', new.vat_code using errcode = 'check_violation'; end if;
  new.vat_rate := v.rate; new.vat_category := v.zatca_category;
  return new;
end $$;
create trigger supplier_invoice_lines_before before insert or update or delete on public.supplier_invoice_lines
  for each row execute function public.supplier_invoice_lines_before();

create or replace function public.supplier_invoice_lines_recalc() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.recalculate_supplier_invoice(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;
create trigger supplier_invoice_lines_recalc after insert or update or delete on public.supplier_invoice_lines
  for each row execute function public.supplier_invoice_lines_recalc();

create or replace function public.supplier_invoices_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_wf boolean := coalesce(current_setting('rms.bill_wf', true), '') = new.id::text;
        v_calc boolean := coalesce(current_setting('rms.bill_calc', true), '') = new.id::text;
        v_paid boolean := coalesce(current_setting('rms.bill_paid', true), '') = new.id::text;
begin
  if v_wf or v_calc then return new; end if;
  if v_paid then
    if (to_jsonb(new) - 'amount_paid' - 'retention_released' - 'updated_at') <> (to_jsonb(old) - 'amount_paid' - 'retention_released' - 'updated_at') then
      raise exception 'Payments may only change the amount paid' using errcode = 'insufficient_privilege';
    end if;
    return new;
  end if;
  if old.status <> 'draft' then
    raise exception 'A posted supplier invoice cannot be changed; cancel it and enter it again' using errcode = 'insufficient_privilege';
  end if;
  if (new.number, new.status, new.subtotal, new.vat_total, new.total_amount, new.retention_amount, new.amount_payable, new.amount_paid,
      new.retention_released, new.posted_at, new.posted_by, new.match_status, new.match_details, new.po_id, new.supplier_id)
     is distinct from (old.number, old.status, old.subtotal, old.vat_total, old.total_amount, old.retention_amount, old.amount_payable, old.amount_paid,
      old.retention_released, old.posted_at, old.posted_by, old.match_status, old.match_details, old.po_id, old.supplier_id) then
    raise exception 'Totals, matching and status are set by the system' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger supplier_invoices_guard before update on public.supplier_invoices for each row execute function public.supplier_invoices_guard();

create or replace function public.supplier_invoices_params_recalc() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'draft' then perform public.recalculate_supplier_invoice(new.id); end if;
  return null;
end $$;
create trigger supplier_invoices_params_recalc after update of retention_pct, advance_recovery on public.supplier_invoices
  for each row execute function public.supplier_invoices_params_recalc();

-- 3-way match: each PO line invoiced ≤ received, at the PO price. Returns the details; variance → needs an override.
create or replace function public.match_supplier_invoice(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.supplier_invoices%rowtype; l record; v_lines jsonb := '[]'::jsonb; v_var boolean := false; v_po_total numeric; v_billed numeric;
begin
  select * into s from public.supplier_invoices where id = p_id;
  if s.po_id is null then return jsonb_build_object('status', 'no_po', 'lines', '[]'::jsonb); end if;
  for l in
    select sl.line_ref, max(sl.description) as description, sum(sl.quantity) as qty, round(sum(sl.net_amount) / nullif(sum(sl.quantity), 0), 4) as price,
           max(pl.quantity) as po_qty, max(pl.net_amount / pl.quantity) as po_price,
           public.po_line_received(sl.line_ref) as received, public.po_line_invoiced(sl.line_ref) as invoiced_before
      from public.supplier_invoice_lines sl
      join lateral (select * from public.purchase_order_lines x where x.line_ref = sl.line_ref
                     and x.order_id in (select id from public.purchase_orders where root_id = (select root_id from public.purchase_orders where id = s.po_id)
                                        and status not in ('draft', 'pending_approval', 'approved', 'cancelled'))
                     order by (x.order_id = s.po_id) desc, x.created_at desc limit 1) pl on true
     where sl.invoice_id = p_id and sl.line_ref is not null group by sl.line_ref
  loop
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('description', l.description, 'invoiced_qty', l.qty, 'invoiced_before', l.invoiced_before,
      'received_qty', l.received, 'ordered_qty', l.po_qty, 'invoice_price', l.price, 'po_price', round(l.po_price, 4),
      'qty_ok', l.invoiced_before + l.qty <= l.received, 'price_ok', l.price <= round(l.po_price, 4) + 0.0001));
    if l.invoiced_before + l.qty > l.received or l.price > round(l.po_price, 4) + 0.0001 then v_var := true; end if;
  end loop;
  if exists (select 1 from public.supplier_invoice_lines where invoice_id = p_id and line_ref is null) then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('description', 'Items not on the purchase order', 'qty_ok', false, 'price_ok', false));
    v_var := true;
  end if;
  select taxable_amount into v_po_total from public.purchase_orders where id = s.po_id;
  select coalesce(sum(subtotal), 0) into v_billed from public.supplier_invoices where po_id in
    (select id from public.purchase_orders where root_id = (select root_id from public.purchase_orders where id = s.po_id)) and status = 'posted';
  if v_billed + s.subtotal > v_po_total + 0.005 then v_var := true; end if;
  return jsonb_build_object('status', case when v_var then 'variance' else 'matched' end, 'lines', v_lines,
                            'po_amount', v_po_total, 'billed_before', v_billed, 'this_invoice', s.subtotal);
end $$;

-- Post the invoice to accounts payable. A variance needs procurement.approve and a comment.
create or replace function public.post_supplier_invoice(p_id uuid, p_override_comment text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.supplier_invoices%rowtype; m jsonb; l record; v_journal jsonb := '[]'::jsonb; v_grni numeric; v_root uuid;
begin
  if not public.has_permission('procurement.order') and not public.has_permission('payments.write') then
    raise exception 'You do not have permission to post supplier invoices' using errcode = 'insufficient_privilege';
  end if;
  select * into s from public.supplier_invoices where id = p_id for update;
  if not found then raise exception 'Supplier invoice not found' using errcode = 'no_data_found'; end if;
  if s.status <> 'draft' then raise exception 'This supplier invoice is already %', s.status using errcode = 'check_violation'; end if;
  if s.total_amount <= 0 then raise exception 'Add the invoice lines first' using errcode = 'check_violation'; end if;
  if s.vat_total > 0 and not exists (select 1 from public.suppliers where id = s.supplier_id and vat_number is not null) then
    raise exception 'The supplier has no VAT number, so VAT on this invoice cannot be recovered; add it to the supplier first'
      using errcode = 'check_violation';
  end if;
  v_root := (select root_id from public.purchase_orders where id = s.po_id);
  if s.advance_recovery > public.supplier_advance_open(s.supplier_id, v_root) then
    raise exception 'The advance recovered is more than the supplier''s unrecovered advance (%)', public.supplier_advance_open(s.supplier_id, v_root)
      using errcode = 'check_violation';
  end if;
  m := public.match_supplier_invoice(p_id);
  if m ->> 'status' = 'variance' then
    if not public.has_permission('procurement.approve') or length(trim(coalesce(p_override_comment, ''))) = 0 then
      raise exception 'The invoice does not match the purchase order and goods received; an approver must post it with a comment'
        using errcode = 'check_violation';
    end if;
    perform public.decide_approval('supplier_invoice', p_id, s.subtotal, s.created_by, 'procurement.approve', true, p_override_comment);
  end if;

  -- Lines on the PO clear goods-received-not-invoiced at PO cost (up to what was received); any difference is project cost.
  for l in select sl.*, (select x.net_amount / x.quantity from public.purchase_order_lines x where x.line_ref = sl.line_ref
                          order by (x.order_id = s.po_id) desc, x.created_at desc limit 1) as po_unit
             from public.supplier_invoice_lines sl where sl.invoice_id = p_id loop
    if l.line_ref is not null then
      v_grni := round(least(l.quantity, greatest(public.po_line_received(l.line_ref) - public.po_line_invoiced(l.line_ref), 0)) * l.po_unit, 2);
      v_journal := v_journal || jsonb_build_array(
        jsonb_build_object('account_key', 'grni', 'amount', v_grni, 'supplier_id', s.supplier_id, 'project_id', s.project_id, 'description', l.description),
        jsonb_build_object('account', public.cost_account(l.cost_category, s.project_id), 'amount', l.net_amount - v_grni, 'project_id', s.project_id,
                           'supplier_id', s.supplier_id, 'cost_category', case when s.project_id is not null then l.cost_category end,
                           'description', 'Price/quantity difference: ' || l.description));
    else
      v_journal := v_journal || jsonb_build_array(jsonb_build_object('account', public.cost_account(l.cost_category, s.project_id), 'amount', l.net_amount,
        'project_id', s.project_id, 'supplier_id', s.supplier_id, 'cost_category', case when s.project_id is not null then l.cost_category end,
        'description', l.description));
    end if;
  end loop;
  v_journal := v_journal || jsonb_build_array(
    jsonb_build_object('account_key', 'vat_input', 'amount', s.vat_total, 'supplier_id', s.supplier_id),
    jsonb_build_object('account_key', 'payables', 'amount', -s.amount_payable, 'supplier_id', s.supplier_id, 'project_id', s.project_id),
    jsonb_build_object('account_key', 'retention_payable', 'amount', -s.retention_amount, 'supplier_id', s.supplier_id, 'project_id', s.project_id),
    jsonb_build_object('account_key', 'supplier_advances', 'amount', -s.advance_recovery, 'supplier_id', s.supplier_id, 'project_id', s.project_id));

  perform set_config('rms.bill_wf', p_id::text, true);
  update public.supplier_invoices set status = 'posted', posted_at = now(), posted_by = auth.uid(), match_status = m ->> 'status', match_details = m,
         override_comment = nullif(trim(coalesce(p_override_comment, '')), ''),
         due_date = coalesce(s.due_date, s.invoice_date + coalesce((select payment_terms_days from public.suppliers where id = s.supplier_id), 30))
   where id = p_id;
  perform set_config('rms.bill_wf', '', true);
  perform public.post_journal(s.invoice_date, 'supplier_invoice', p_id, 'post', 'Supplier invoice ' || s.supplier_invoice_number || ' (' || s.number || ')', v_journal);
  perform public.log_event('supplier_invoices', p_id::text, 'posted', jsonb_build_object('match', m ->> 'status'));
  return m;
end $$;

create or replace function public.cancel_supplier_invoice(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare s public.supplier_invoices%rowtype;
begin
  if not public.has_permission('procurement.order') and not public.has_permission('payments.write') then
    raise exception 'You do not have permission for this action' using errcode = 'insufficient_privilege';
  end if;
  select * into s from public.supplier_invoices where id = p_id for update;
  if s.status = 'cancelled' then raise exception 'Already cancelled' using errcode = 'check_violation'; end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'A reason is required' using errcode = 'check_violation'; end if;
  if s.amount_paid > 0 or s.retention_released > 0 then
    raise exception 'Void the payments on this invoice first' using errcode = 'check_violation';
  end if;
  perform set_config('rms.bill_wf', p_id::text, true);
  update public.supplier_invoices set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason where id = p_id;
  perform set_config('rms.bill_wf', '', true);
  if s.status = 'posted' then
    perform public.reverse_source('supplier_invoice', p_id, null, (now() at time zone 'Asia/Riyadh')::date, 'Supplier invoice cancelled: ' || p_reason);
  end if;
  perform public.log_event('supplier_invoices', p_id::text, s.status || ' → cancelled', jsonb_build_object('reason', p_reason));
end $$;

-- ---------------------------------------------------------------------------
-- Payments to suppliers: against an invoice, an advance on an order, or release of retention
-- ---------------------------------------------------------------------------

create table public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  kind text not null default 'invoice' check (kind in ('invoice', 'advance', 'retention')),
  invoice_id uuid references public.supplier_invoices (id) on delete restrict,
  po_id uuid references public.purchase_orders (id) on delete restrict,
  payment_date date not null,
  amount numeric(18, 2) not null check (amount > 0),
  method public.payment_method not null default 'bank_transfer',
  bank_account_code text references public.accounts (code),
  reference text,
  notes text,
  voided_at timestamptz,
  voided_by uuid references public.app_users (id),
  void_reason text,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  constraint supplier_payments_target check ((kind = 'advance' and po_id is not null and invoice_id is null)
                                             or (kind in ('invoice', 'retention') and invoice_id is not null))
);
create index supplier_payments_invoice_idx on public.supplier_payments (invoice_id);
create index supplier_payments_po_idx on public.supplier_payments (po_id);

-- Advances paid to the supplier on this order chain that have not been recovered yet.
create or replace function public.supplier_advance_open(p_supplier_id uuid, p_po_root uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(p.amount) from public.supplier_payments p join public.purchase_orders o on o.id = p.po_id
                    where p.kind = 'advance' and p.voided_at is null and p.supplier_id = p_supplier_id
                      and (p_po_root is null or o.root_id = p_po_root)), 0)
       - coalesce((select sum(s.advance_recovery) from public.supplier_invoices s left join public.purchase_orders o on o.id = s.po_id
                    where s.status = 'posted' and s.supplier_id = p_supplier_id and (p_po_root is null or o.root_id = p_po_root)), 0)
$$;

create or replace function public.supplier_payments_before() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.supplier_invoices%rowtype; po public.purchase_orders%rowtype; v_open numeric;
begin
  if tg_op = 'INSERT' then
    if new.bank_account_code is not null and not exists (select 1 from public.accounts where code = new.bank_account_code and is_bank and is_active) then
      raise exception 'Choose an active bank or cash account' using errcode = 'check_violation';
    end if;
    if new.kind in ('invoice', 'retention') then
      select * into s from public.supplier_invoices where id = new.invoice_id for update;
      if s.status <> 'posted' then raise exception 'Payments can only be made against posted supplier invoices' using errcode = 'check_violation'; end if;
      v_open := case when new.kind = 'invoice' then s.amount_payable - s.amount_paid else s.retention_amount - s.retention_released end;
      if new.amount > v_open then
        raise exception 'The payment is more than the amount outstanding (%)', v_open using errcode = 'check_violation';
      end if;
      new.supplier_id := s.supplier_id; new.po_id := s.po_id;
    else
      select * into po from public.purchase_orders where id = new.po_id;
      if po.status not in ('approved', 'issued', 'partially_received', 'received') then
        raise exception 'Advances can only be paid on an approved or issued order' using errcode = 'check_violation';
      end if;
      v_open := po.total_amount - coalesce((select sum(amount) from public.supplier_payments p join public.purchase_orders o on o.id = p.po_id
                                             where p.kind = 'advance' and p.voided_at is null and o.root_id = po.root_id), 0);
      if new.amount > v_open then raise exception 'Advances cannot exceed the order value (% left)', v_open using errcode = 'check_violation'; end if;
      new.supplier_id := po.supplier_id;
    end if;
    new.number := public.next_document_number('supplier_payment', 'PAY', true, 5);
    new.voided_at := null; new.voided_by := null; new.void_reason := null;
    return new;
  end if;
  if (to_jsonb(new) - 'voided_at' - 'voided_by' - 'void_reason') <> (to_jsonb(old) - 'voided_at' - 'voided_by' - 'void_reason')
     or old.voided_at is not null or new.voided_at is null or length(trim(coalesce(new.void_reason, ''))) = 0 then
    raise exception 'A payment can only be voided once, with a reason' using errcode = 'check_violation';
  end if;
  if new.kind = 'advance' and public.supplier_advance_open(new.supplier_id, (select root_id from public.purchase_orders where id = new.po_id)) < new.amount then
    raise exception 'Part of this advance has already been recovered on a supplier invoice' using errcode = 'check_violation';
  end if;
  new.voided_by := auth.uid();
  return new;
end $$;
create trigger supplier_payments_before before insert or update on public.supplier_payments
  for each row execute function public.supplier_payments_before();

create or replace function public.supplier_payments_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_proj uuid; v_bank text;
begin
  if new.invoice_id is not null then
    perform set_config('rms.bill_paid', new.invoice_id::text, true);
    update public.supplier_invoices
       set amount_paid = (select coalesce(sum(amount), 0) from public.supplier_payments where invoice_id = new.invoice_id and kind = 'invoice' and voided_at is null),
           retention_released = (select coalesce(sum(amount), 0) from public.supplier_payments where invoice_id = new.invoice_id and kind = 'retention' and voided_at is null)
     where id = new.invoice_id;
    perform set_config('rms.bill_paid', '', true);
  end if;
  if tg_op = 'INSERT' then
    v_proj := coalesce((select project_id from public.supplier_invoices where id = new.invoice_id), (select project_id from public.purchase_orders where id = new.po_id));
    v_bank := coalesce(new.bank_account_code, public.account_for('bank'));
    perform public.post_journal(new.payment_date, 'supplier_payment', new.id, 'payment', 'Supplier payment ' || new.number, jsonb_build_array(
      jsonb_build_object('account_key', case new.kind when 'invoice' then 'payables' when 'advance' then 'supplier_advances' else 'retention_payable' end,
                         'amount', new.amount, 'supplier_id', new.supplier_id, 'project_id', v_proj),
      jsonb_build_object('account', v_bank, 'amount', -new.amount, 'supplier_id', new.supplier_id, 'project_id', v_proj)));
  elsif old.voided_at is null and new.voided_at is not null then
    perform public.reverse_source('supplier_payment', new.id, null, (now() at time zone 'Asia/Riyadh')::date, 'Payment voided: ' || new.void_reason);
  end if;
  return null;
end $$;
create trigger supplier_payments_after after insert or update on public.supplier_payments
  for each row execute function public.supplier_payments_after();


-- ---------------------------------------------------------------------------
-- Project cost position and budget checks
-- ---------------------------------------------------------------------------

-- Per cost category: budget, committed (ordered, not yet received), actual (ledger), supplier invoiced, available.
create or replace function public.project_cost_position(p_project_id uuid)
returns table (cost_category text, budget numeric, committed numeric, actual numeric, invoiced numeric, available numeric)
language sql stable security definer set search_path = public as $$
  with cats as (
    select code from public.cost_categories
  ), bud as (
    select b.cost_category, b.amount from public.project_budget_lines b where b.project_id = p_project_id
  ), com as (
    select coalesce(l.cost_category, o.cost_category) as cost_category,
           sum(round(greatest(l.quantity - public.po_line_received(l.line_ref), 0) * l.net_amount / l.quantity, 2)) as amount
      from public.purchase_orders o join public.purchase_order_lines l on l.order_id = o.id
     where o.project_id = p_project_id and o.status in ('approved', 'issued', 'partially_received', 'received')
       and not (o.status = 'approved' and o.amends_id is not null)   -- the original stays committed until the amendment is issued
     group by 1
  ), act as (
    select coalesce(j.cost_category, 'other') as cost_category, sum(j.debit - j.credit) as amount
      from public.journal_lines j join public.accounts a on a.code = j.account_code
     where j.project_id = p_project_id and a.type = 'expense' group by 1
  ), inv as (
    select coalesce(sl.cost_category, 'other') as cost_category, sum(sl.net_amount) as amount
      from public.supplier_invoices s join public.supplier_invoice_lines sl on sl.invoice_id = s.id
     where s.project_id = p_project_id and s.status = 'posted' group by 1
  )
  select c.code, coalesce(bud.amount, 0), coalesce(com.amount, 0), coalesce(act.amount, 0), coalesce(inv.amount, 0),
         coalesce(bud.amount, 0) - coalesce(com.amount, 0) - coalesce(act.amount, 0)
    from cats c left join bud on bud.cost_category = c.code left join com on com.cost_category = c.code
    left join act on act.cost_category = c.code left join inv on inv.cost_category = c.code
   where bud.amount is not null or com.amount is not null or act.amount is not null or inv.amount is not null
$$;

-- Would spending p_amount in a category exceed the budget? Unallocated budget counts as available to every category.
create or replace function public.budget_check(p_project_id uuid, p_category text, p_amount numeric, p_exclude_po uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c record; g record; v_excl numeric := 0; v_avail numeric;
begin
  select * into c from public.project_cost_position(p_project_id) where cost_category = p_category;
  select * into g from public.project_cost_position(p_project_id) where cost_category = 'general';
  if p_exclude_po is not null then
    select coalesce(sum(round(greatest(l.quantity - public.po_line_received(l.line_ref), 0) * l.net_amount / l.quantity, 2)), 0) into v_excl
      from public.purchase_order_lines l join public.purchase_orders o on o.id = l.order_id
     where o.id = p_exclude_po and o.status in ('approved', 'issued', 'partially_received', 'received')
       and coalesce(l.cost_category, o.cost_category) = p_category;
  end if;
  v_avail := coalesce(c.available, 0) + v_excl + case when p_category <> 'general' then greatest(coalesce(g.available, 0), 0) else 0 end;
  return jsonb_build_object('cost_category', p_category, 'budget', coalesce(c.budget, 0), 'committed', coalesce(c.committed, 0) - v_excl,
    'actual', coalesce(c.actual, 0), 'unallocated', case when p_category <> 'general' then greatest(coalesce(g.available, 0), 0) else 0 end,
    'available', v_avail, 'requested', p_amount, 'over_budget', p_amount > v_avail, 'checked_at', now());
end $$;

create or replace function public.po_budget_check(p_po_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare po public.purchase_orders%rowtype; r record; v_lines jsonb := '[]'::jsonb; v_over boolean := false; b jsonb;
begin
  select * into po from public.purchase_orders where id = p_po_id;
  -- Only what is still to be delivered is new spending; goods already received are in actual cost.
  for r in select coalesce(cost_category, po.cost_category) as cat,
                  sum(round(greatest(quantity - public.po_line_received(line_ref), 0) * net_amount / quantity, 2)) as amt
             from public.purchase_order_lines where order_id = p_po_id group by 1 loop
    -- An amendment replaces its original, so the original's open commitment is not counted twice.
    b := public.budget_check(po.project_id, r.cat, r.amt, po.amends_id);
    v_lines := v_lines || jsonb_build_array(b);
    v_over := v_over or (b ->> 'over_budget')::boolean;
  end loop;
  return jsonb_build_object('over_budget', v_over, 'categories', v_lines);
end $$;

-- ---------------------------------------------------------------------------
-- Audit, attachments, grants and row-level security
-- ---------------------------------------------------------------------------

create trigger audit_supplier_quotes after insert or update on public.supplier_quotes for each row execute function public.audit_trigger();
create trigger audit_supplier_quote_lines after insert or update or delete on public.supplier_quote_lines for each row execute function public.audit_trigger();
create trigger audit_goods_receipts after insert or update on public.goods_receipts for each row execute function public.audit_trigger();
create trigger audit_supplier_invoices after insert or update on public.supplier_invoices for each row execute function public.audit_trigger();
create trigger audit_supplier_invoice_lines after insert or update or delete on public.supplier_invoice_lines for each row execute function public.audit_trigger();
create trigger audit_supplier_payments after insert or update on public.supplier_payments for each row execute function public.audit_trigger();

grant select, insert, update, delete on public.supplier_quotes, public.supplier_quote_lines, public.supplier_invoice_lines to authenticated;
grant select, insert, update on public.supplier_invoices, public.supplier_payments to authenticated;
grant select on public.goods_receipts, public.goods_receipt_lines to authenticated;
revoke delete on public.supplier_quotes from authenticated;
grant all on public.supplier_quotes, public.supplier_quote_lines, public.goods_receipts, public.goods_receipt_lines, public.supplier_invoices,
  public.supplier_invoice_lines, public.supplier_payments to service_role;
revoke all on function public.recalculate_supplier_invoice(uuid), public.refresh_po_receipt_status(uuid) from public, anon, authenticated;
revoke execute on function public.issue_purchase_order(uuid), public.amend_purchase_order(uuid), public.select_supplier_quote(uuid, text),
  public.receive_goods(uuid, date, text, text, jsonb), public.cancel_goods_receipt(uuid, text), public.post_supplier_invoice(uuid, text),
  public.cancel_supplier_invoice(uuid, text), public.match_supplier_invoice(uuid), public.project_cost_position(uuid),
  public.budget_check(uuid, text, numeric, uuid), public.po_budget_check(uuid) from public, anon;
grant execute on function public.issue_purchase_order(uuid), public.amend_purchase_order(uuid), public.select_supplier_quote(uuid, text),
  public.receive_goods(uuid, date, text, text, jsonb), public.cancel_goods_receipt(uuid, text), public.post_supplier_invoice(uuid, text),
  public.cancel_supplier_invoice(uuid, text), public.match_supplier_invoice(uuid), public.project_cost_position(uuid),
  public.budget_check(uuid, text, numeric, uuid), public.po_budget_check(uuid) to authenticated;

alter table public.supplier_quotes enable row level security;
alter table public.supplier_quote_lines enable row level security;
alter table public.goods_receipts enable row level security;
alter table public.goods_receipt_lines enable row level security;
alter table public.supplier_invoices enable row level security;
alter table public.supplier_invoice_lines enable row level security;
alter table public.supplier_payments enable row level security;

create policy supplier_quotes_select on public.supplier_quotes for select to authenticated using (public.has_permission('procurement.read'));
create policy supplier_quotes_write on public.supplier_quotes for all to authenticated
  using (public.has_permission('procurement.order')) with check (public.has_permission('procurement.order'));
create policy supplier_quote_lines_select on public.supplier_quote_lines for select to authenticated using (public.has_permission('procurement.read'));
create policy supplier_quote_lines_write on public.supplier_quote_lines for all to authenticated
  using (public.has_permission('procurement.order')) with check (public.has_permission('procurement.order'));
create policy goods_receipts_select on public.goods_receipts for select to authenticated using (public.has_permission('procurement.read'));
create policy goods_receipt_lines_select on public.goods_receipt_lines for select to authenticated using (public.has_permission('procurement.read'));
create policy supplier_invoices_select on public.supplier_invoices for select to authenticated
  using (public.has_permission('procurement.read') or public.has_permission('invoices.read'));
create policy supplier_invoices_write on public.supplier_invoices for insert to authenticated
  with check (public.has_permission('procurement.order') or public.has_permission('payments.write'));
create policy supplier_invoices_update on public.supplier_invoices for update to authenticated
  using (public.has_permission('procurement.order') or public.has_permission('payments.write'))
  with check (public.has_permission('procurement.order') or public.has_permission('payments.write'));
create policy supplier_invoice_lines_select on public.supplier_invoice_lines for select to authenticated
  using (public.has_permission('procurement.read') or public.has_permission('invoices.read'));
create policy supplier_invoice_lines_write on public.supplier_invoice_lines for all to authenticated
  using (public.has_permission('procurement.order') or public.has_permission('payments.write'))
  with check (public.has_permission('procurement.order') or public.has_permission('payments.write'));
create policy supplier_payments_select on public.supplier_payments for select to authenticated
  using (public.has_permission('procurement.read') or public.has_permission('invoices.read'));
create policy supplier_payments_insert on public.supplier_payments for insert to authenticated with check (public.has_permission('payments.write'));
create policy supplier_payments_update on public.supplier_payments for update to authenticated
  using (public.has_permission('payments.write')) with check (public.has_permission('payments.write'));
