-- RMS Phase 3a: customer invoices, credit and debit notes, proforma invoices and payments received.
--
-- Rules
--   * Amounts are calculated only by public.recalculate_invoice() (deterministic SQL, no AI, no client input).
--   * Drafts have no number. Issuing assigns the next gap-free number, freezes seller and buyer details,
--     stamps the issue time and builds the ZATCA QR (Phase 1 TLV: seller, VAT no., time, total, VAT).
--   * Issued documents never change. A mistake is corrected with a credit or debit note.
--   * Tax documents (invoice, credit note, debit note) are issued in SAR only in this version.
--   * This is not yet ZATCA Phase 2 (XML, cryptographic stamp, clearance/reporting); nothing here is
--     described as compliant until it passes ZATCA's own tests.

create type public.invoice_kind as enum ('invoice', 'credit_note', 'debit_note', 'proforma');
create type public.invoice_status as enum ('draft', 'issued', 'cancelled');
create type public.payment_method as enum ('bank_transfer', 'cheque', 'cash', 'card', 'other');

insert into public.permissions (code, module, description) values
  ('invoices.read', 'finance', 'View invoices, notes and payments received'),
  ('invoices.write', 'finance', 'Prepare draft invoices and notes'),
  ('invoices.issue', 'finance', 'Issue invoices and notes (final, numbered, cannot be edited)'),
  ('payments.write', 'finance', 'Record and void payments received');

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r
join public.permissions p on p.code in ('invoices.read', 'invoices.write', 'invoices.issue', 'payments.write')
where r.code in ('administrator', 'general_manager', 'finance')
on conflict do nothing;
insert into public.role_permissions (role_id, permission_code)
select r.id, 'invoices.read' from public.roles r where r.code = 'project_management'
on conflict do nothing;

alter table public.company_settings
  add column building_number text,
  add column street text,
  add column district text,
  add column city text default 'Jeddah',
  add column postal_code text,
  add column additional_number text,
  add column unified_number text,
  add column bank_name text,
  add column bank_iban text,
  add column bank_account_name text,
  add column invoice_terms_en text,
  add column invoice_terms_ar text;

-- ---------------------------------------------------------------------------
-- Invoices and notes
-- ---------------------------------------------------------------------------

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  number text unique,                                   -- assigned on issue
  kind public.invoice_kind not null default 'invoice',
  zatca_type text not null default 'standard' check (zatca_type in ('standard', 'simplified')),
  status public.invoice_status not null default 'draft',
  customer_id uuid not null references public.customers (id) on delete restrict,
  contract_id uuid references public.contracts (id) on delete restrict,
  project_id uuid references public.projects (id) on delete restrict,
  original_invoice_id uuid references public.invoices (id) on delete restrict,
  note_reason text,                                     -- required for credit/debit notes
  currency char(3) not null default 'SAR' references public.currencies (code),
  supply_date date,
  supply_end_date date,
  due_date date,
  customer_reference text,                              -- client PO / claim reference
  title text,
  notes_en text, notes_ar text,
  payment_terms_en text, payment_terms_ar text,
  retention_pct numeric(5, 2) not null default 0 check (retention_pct between 0 and 100),
  advance_deduction numeric(18, 2) not null default 0 check (advance_deduction >= 0),

  -- Calculated by public.recalculate_invoice(); never written by clients.
  subtotal numeric(18, 2) not null default 0,           -- Σ line gross (qty × price)
  discount_total numeric(18, 2) not null default 0,     -- Σ line discounts
  taxable_amount numeric(18, 2) not null default 0,     -- subtotal − discounts
  vat_total numeric(18, 2) not null default 0,
  total_amount numeric(18, 2) not null default 0,       -- taxable + VAT
  retention_amount numeric(18, 2) not null default 0,   -- round(taxable × retention%, 2), held by client
  amount_payable numeric(18, 2) not null default 0,     -- total − retention − advance deduction
  amount_paid numeric(18, 2) not null default 0,        -- maintained from customer_payments

  -- Frozen at issue
  issued_at timestamptz,
  issue_date date,
  issued_by uuid references public.app_users (id),
  seller_snapshot jsonb,
  buyer_snapshot jsonb,
  zatca_qr text,
  pdf_attachment_id uuid references public.attachments (id),
  cancelled_at timestamptz,
  cancelled_by uuid references public.app_users (id),
  cancel_reason text,

  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint invoices_note_original check ((kind in ('credit_note', 'debit_note')) = (original_invoice_id is not null)),
  constraint invoices_supply_period check (supply_end_date is null or supply_date is null or supply_end_date >= supply_date)
);
create index invoices_customer_idx on public.invoices (customer_id);
create index invoices_contract_idx on public.invoices (contract_id);
create index invoices_original_idx on public.invoices (original_invoice_id);
create index invoices_status_idx on public.invoices (status, kind);
create trigger invoices_updated before update on public.invoices for each row execute function public.set_updated_at();

create table public.invoice_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  sort_order integer not null default 0,
  item_code text,
  description_en text not null check (length(trim(description_en)) > 0),
  description_ar text,
  unit text not null default 'LS',
  quantity numeric(18, 3) not null default 1 check (quantity > 0),
  unit_price numeric(18, 4) not null default 0 check (unit_price >= 0),
  discount_amount numeric(18, 2) not null default 0 check (discount_amount >= 0),
  vat_code text not null default 'S15' references public.vat_codes (code),
  vat_rate numeric(5, 2) not null default 15 check (vat_rate >= 0 and vat_rate < 100),
  vat_category char(1) not null default 'S' check (vat_category in ('S', 'Z', 'E', 'O')),
  vat_exemption_reason text,                             -- required for Z, E and O
  gross_amount numeric(18, 2) generated always as (round(quantity * unit_price, 2)) stored,
  net_amount numeric(18, 2) generated always as (round(quantity * unit_price, 2) - discount_amount) stored,
  vat_amount numeric(18, 2) generated always as (round((round(quantity * unit_price, 2) - discount_amount) * vat_rate / 100, 2)) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint invoice_lines_discount check (discount_amount <= round(quantity * unit_price, 2))
);
create index invoice_lines_invoice_idx on public.invoice_lines (invoice_id, sort_order);
create trigger invoice_lines_updated before update on public.invoice_lines for each row execute function public.set_updated_at();

-- VAT rate and category always follow the VAT code.
create or replace function public.invoice_lines_vat() returns trigger
language plpgsql security definer set search_path = public as $$
declare v public.vat_codes%rowtype;
begin
  select * into v from public.vat_codes where code = new.vat_code and is_active;
  if not found then raise exception 'Unknown VAT code %', new.vat_code using errcode = 'check_violation'; end if;
  new.vat_rate := v.rate;
  new.vat_category := v.zatca_category;
  return new;
end $$;
create trigger invoice_lines_vat before insert or update of vat_code on public.invoice_lines
  for each row execute function public.invoice_lines_vat();

-- ---------------------------------------------------------------------------
-- Calculation (authoritative). Mirrored in packages/shared/src/invoice.ts for previews.
--   line gross      = round(qty × unit price, 2)
--   line net        = gross − line discount
--   line VAT        = round(net × rate%, 2)                    (shown per line)
--   taxable         = Σ line net
--   VAT total       = Σ per VAT rate of round(Σ net at that rate × rate%, 2)   (ZATCA category totals)
--   total           = taxable + VAT total
--   retention       = round(taxable × retention%, 2)
--   payable         = total − retention − advance deduction
-- ---------------------------------------------------------------------------

create or replace function public.recalculate_invoice(p_invoice_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  inv public.invoices%rowtype;
  v_sub numeric; v_disc numeric; v_taxable numeric; v_vat numeric; v_ret numeric;
begin
  select * into inv from public.invoices where id = p_invoice_id for update;
  if not found or inv.status <> 'draft' then return; end if;
  select coalesce(sum(gross_amount), 0), coalesce(sum(discount_amount), 0), coalesce(sum(net_amount), 0)
    into v_sub, v_disc, v_taxable from public.invoice_lines where invoice_id = p_invoice_id;
  select coalesce(sum(cat_vat), 0) into v_vat from (
    select round(sum(net_amount) * vat_rate / 100, 2) as cat_vat
    from public.invoice_lines where invoice_id = p_invoice_id group by vat_category, vat_rate
  ) c;
  v_ret := round(v_taxable * inv.retention_pct / 100, 2);
  perform set_config('rms.invoice_calc', p_invoice_id::text, true);
  update public.invoices
     set subtotal = v_sub, discount_total = v_disc, taxable_amount = v_taxable, vat_total = v_vat,
         total_amount = v_taxable + v_vat, retention_amount = v_ret,
         amount_payable = v_taxable + v_vat - v_ret - inv.advance_deduction
   where id = p_invoice_id;
  perform set_config('rms.invoice_calc', '', true);
end $$;

create or replace function public.invoice_lines_recalc() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.recalculate_invoice(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;
create trigger invoice_lines_recalc after insert or delete or update on public.invoice_lines
  for each row execute function public.invoice_lines_recalc();

create or replace function public.invoice_params_recalc() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.recalculate_invoice(new.id);
  return null;
end $$;
create trigger invoice_params_recalc after update of retention_pct, advance_deduction on public.invoices
  for each row execute function public.invoice_params_recalc();

-- Lines can only change while the invoice is a draft.
create or replace function public.invoice_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_status public.invoice_status;
begin
  select status into v_status from public.invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if v_status is distinct from 'draft' then
    raise exception 'Only draft invoices can be edited; issue a credit or debit note instead' using errcode = 'insufficient_privilege';
  end if;
  if tg_op = 'UPDATE' and new.invoice_id <> old.invoice_id then
    raise exception 'A line cannot move to another invoice' using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end $$;
create trigger invoice_lines_guard before insert or update or delete on public.invoice_lines
  for each row execute function public.invoice_lines_guard();

-- Calculated, numbering and issue fields are written only by the functions below.
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
    new.subtotal := 0; new.discount_total := 0; new.taxable_amount := 0; new.vat_total := 0;
    new.total_amount := 0; new.retention_amount := 0; new.amount_payable := 0 - new.advance_deduction; new.amount_paid := 0;
    return new;
  end if;

  if v_paid then
    if (to_jsonb(new) - 'amount_paid' - 'updated_at') <> (to_jsonb(old) - 'amount_paid' - 'updated_at') then
      raise exception 'Payment update may only change the amount paid' using errcode = 'insufficient_privilege';
    end if;
    return new;
  end if;

  if old.status <> 'draft' and not v_issue then
    -- Issued and cancelled documents are final. Only the archived PDF link may be attached once.
    if (to_jsonb(new) - 'pdf_attachment_id' - 'updated_at') <> (to_jsonb(old) - 'pdf_attachment_id' - 'updated_at')
       or (old.pdf_attachment_id is not null and new.pdf_attachment_id is distinct from old.pdf_attachment_id) then
      raise exception 'An issued invoice cannot be changed; issue a credit or debit note instead' using errcode = 'insufficient_privilege';
    end if;
    return new;
  end if;

  if not v_issue and (new.status, new.number, new.issued_at, new.issue_date, new.issued_by, new.seller_snapshot, new.buyer_snapshot,
       new.zatca_qr, new.cancelled_at, new.cancelled_by, new.cancel_reason, new.amount_paid)
     is distinct from (old.status, old.number, old.issued_at, old.issue_date, old.issued_by, old.seller_snapshot, old.buyer_snapshot,
       old.zatca_qr, old.cancelled_at, old.cancelled_by, old.cancel_reason, old.amount_paid) then
    raise exception 'Use the issue or cancel action to change an invoice status' using errcode = 'insufficient_privilege';
  end if;
  if not v_calc and not v_issue and (new.subtotal, new.discount_total, new.taxable_amount, new.vat_total, new.total_amount,
       new.retention_amount, new.amount_payable)
     is distinct from (old.subtotal, old.discount_total, old.taxable_amount, old.vat_total, old.total_amount,
       old.retention_amount, old.amount_payable) then
    raise exception 'Invoice totals are calculated by the system' using errcode = 'insufficient_privilege';
  end if;
  if new.kind <> old.kind or new.original_invoice_id is distinct from old.original_invoice_id then
    raise exception 'The document type cannot change after creation' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger invoices_guard before insert or update on public.invoices
  for each row execute function public.invoices_guard();

-- ---------------------------------------------------------------------------
-- ZATCA QR (Phase 1): base64 of TLV records, tag and length one byte each, values UTF-8.
--   1 seller name   2 seller VAT number   3 time stamp (ISO 8601)   4 invoice total with VAT   5 VAT total
-- ---------------------------------------------------------------------------

create or replace function public.zatca_tlv(p_tag integer, p_value text) returns bytea
language plpgsql immutable as $$
declare v bytea := convert_to(p_value, 'UTF8');
begin
  if length(v) > 255 then raise exception 'ZATCA QR value too long for tag %', p_tag; end if;
  return set_byte('\x00'::bytea, 0, p_tag) || set_byte('\x00'::bytea, 0, length(v)) || v;
end $$;

create or replace function public.zatca_qr(p_seller text, p_vat text, p_time timestamptz, p_total numeric, p_vat_total numeric)
returns text
language sql immutable as $$
  select replace(encode(
    public.zatca_tlv(1, p_seller) || public.zatca_tlv(2, p_vat)
    || public.zatca_tlv(3, to_char(p_time at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
    || public.zatca_tlv(4, to_char(p_total, 'FM999999999999990.00'))
    || public.zatca_tlv(5, to_char(p_vat_total, 'FM999999999999990.00')), 'base64'), E'\n', '')
$$;

-- ---------------------------------------------------------------------------
-- Issue and cancel
-- ---------------------------------------------------------------------------

create or replace function public.issue_invoice(p_invoice_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  inv public.invoices%rowtype;
  orig public.invoices%rowtype;
  co public.company_settings%rowtype;
  cu public.customers%rowtype;
  v_now timestamptz := now();
  v_lines integer;
  v_prefix text;
  v_type text;
  v_room numeric;
begin
  if not public.has_permission('invoices.issue') then
    raise exception 'You do not have permission to issue invoices' using errcode = 'insufficient_privilege';
  end if;
  select * into inv from public.invoices where id = p_invoice_id for update;
  if not found then raise exception 'Invoice not found' using errcode = 'no_data_found'; end if;
  if inv.status <> 'draft' then raise exception 'This invoice is already %', inv.status using errcode = 'check_violation'; end if;

  select count(*) into v_lines from public.invoice_lines where invoice_id = p_invoice_id;
  if v_lines = 0 then raise exception 'Add at least one line before issuing' using errcode = 'check_violation'; end if;
  if exists (select 1 from public.invoice_lines where invoice_id = p_invoice_id and vat_category <> 'S'
             and length(trim(coalesce(vat_exemption_reason, ''))) = 0) then
    raise exception 'Zero-rated, exempt and out-of-scope lines need an exemption reason' using errcode = 'check_violation';
  end if;
  if inv.total_amount <= 0 then raise exception 'The invoice total must be more than zero' using errcode = 'check_violation'; end if;

  select * into co from public.company_settings;
  select * into cu from public.customers where id = inv.customer_id;

  if inv.kind <> 'proforma' then
    if inv.currency <> 'SAR' then
      raise exception 'Tax invoices and notes are issued in SAR in this version' using errcode = 'check_violation';
    end if;
    if co.vat_number is null or not public.is_valid_sa_vat_number(co.vat_number) then
      raise exception 'Set the company VAT number in Settings before issuing tax invoices' using errcode = 'check_violation';
    end if;
    if inv.zatca_type = 'standard' and (cu.city is null or length(trim(coalesce(cu.street, cu.district, ''))) = 0) then
      raise exception 'A standard tax invoice needs the customer''s address (street or district and city)' using errcode = 'check_violation';
    end if;
    if inv.supply_date is null then
      update public.invoices set supply_date = (v_now at time zone 'Asia/Riyadh')::date where id = p_invoice_id;
    end if;
  end if;

  if inv.kind in ('credit_note', 'debit_note') then
    if length(trim(coalesce(inv.note_reason, ''))) = 0 then
      raise exception 'A credit or debit note needs a reason' using errcode = 'check_violation';
    end if;
    select * into orig from public.invoices where id = inv.original_invoice_id;
    if orig.kind <> 'invoice' or orig.status <> 'issued' then
      raise exception 'Notes can only refer to an issued invoice' using errcode = 'check_violation';
    end if;
    if orig.customer_id <> inv.customer_id then
      raise exception 'A note must be for the same customer as its invoice' using errcode = 'check_violation';
    end if;
    if inv.kind = 'credit_note' then
      select orig.total_amount - coalesce(sum(total_amount), 0) into v_room
      from public.invoices where original_invoice_id = orig.id and kind = 'credit_note' and status = 'issued';
      if inv.total_amount > v_room then
        raise exception 'Credit notes cannot exceed the invoice total still uncredited (%)', v_room using errcode = 'check_violation';
      end if;
    end if;
  end if;

  v_prefix := case inv.kind when 'invoice' then 'INV' when 'credit_note' then 'CRN' when 'debit_note' then 'DBN' else 'PRF' end;
  perform set_config('rms.invoice_issue', p_invoice_id::text, true);
  update public.invoices
     set status = 'issued',
         number = public.next_document_number('invoice_' || inv.kind::text, v_prefix, true, 5),
         issued_at = v_now,
         issue_date = (v_now at time zone 'Asia/Riyadh')::date,
         issued_by = auth.uid(),
         seller_snapshot = to_jsonb(co) - 'id' - 'updated_at' - 'allow_self_approval' - 'quotation_validity_days',
         buyer_snapshot = jsonb_build_object('code', cu.code, 'name_en', cu.name_en, 'name_ar', cu.name_ar, 'vat_number', cu.vat_number,
           'cr_number', cu.cr_number, 'building_number', cu.building_number, 'street', cu.street, 'district', cu.district,
           'city', cu.city, 'postal_code', cu.postal_code, 'country', cu.country),
         zatca_qr = case when inv.kind = 'proforma' then null
                         else public.zatca_qr(co.legal_name_ar, co.vat_number, v_now, inv.total_amount, inv.vat_total) end,
         due_date = coalesce(inv.due_date, (v_now at time zone 'Asia/Riyadh')::date + cu.payment_terms_days)
   where id = p_invoice_id;
  perform set_config('rms.invoice_issue', '', true);
  perform public.log_event('invoices', p_invoice_id::text, 'issued');
end $$;

-- Only drafts and proformas can be cancelled. Issued tax documents are reversed with a credit note.
create or replace function public.cancel_invoice(p_invoice_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare inv public.invoices%rowtype;
begin
  select * into inv from public.invoices where id = p_invoice_id for update;
  if not found then raise exception 'Invoice not found' using errcode = 'no_data_found'; end if;
  if inv.status = 'draft' then
    if not public.has_permission('invoices.write') then
      raise exception 'You do not have permission for this action' using errcode = 'insufficient_privilege';
    end if;
  elsif inv.status = 'issued' and inv.kind = 'proforma' then
    if not public.has_permission('invoices.issue') then
      raise exception 'You do not have permission for this action' using errcode = 'insufficient_privilege';
    end if;
  else
    raise exception 'An issued tax document cannot be cancelled; issue a credit note instead' using errcode = 'check_violation';
  end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'A reason is required' using errcode = 'check_violation';
  end if;
  perform set_config('rms.invoice_issue', p_invoice_id::text, true);
  update public.invoices set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = p_reason
   where id = p_invoice_id;
  perform set_config('rms.invoice_issue', '', true);
end $$;

-- ---------------------------------------------------------------------------
-- Payments received
-- ---------------------------------------------------------------------------

create table public.customer_payments (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  invoice_id uuid not null references public.invoices (id) on delete restrict,
  customer_id uuid not null references public.customers (id) on delete restrict,
  payment_date date not null,
  amount numeric(18, 2) not null check (amount > 0),
  method public.payment_method not null default 'bank_transfer',
  reference text,
  notes text,
  voided_at timestamptz,
  voided_by uuid references public.app_users (id),
  void_reason text,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index customer_payments_invoice_idx on public.customer_payments (invoice_id);

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
    v_open := inv.amount_payable - inv.amount_paid - coalesce((select sum(total_amount) from public.invoices
               where original_invoice_id = inv.id and kind = 'credit_note' and status = 'issued'), 0);
    if new.amount > v_open then
      raise exception 'The payment is more than the amount outstanding (%)', v_open using errcode = 'check_violation';
    end if;
    new.customer_id := inv.customer_id;
    new.number := public.next_document_number('receipt', 'RCT', true, 5);
    new.voided_at := null; new.voided_by := null; new.void_reason := null;
    return new;
  end if;
  -- Updates: only voiding, once, with a reason.
  if (to_jsonb(new) - 'voided_at' - 'voided_by' - 'void_reason') <> (to_jsonb(old) - 'voided_at' - 'voided_by' - 'void_reason')
     or old.voided_at is not null or new.voided_at is null or length(trim(coalesce(new.void_reason, ''))) = 0 then
    raise exception 'A payment can only be voided once, with a reason' using errcode = 'check_violation';
  end if;
  new.voided_by := auth.uid();
  return new;
end $$;
create trigger customer_payments_before before insert or update on public.customer_payments
  for each row execute function public.customer_payments_before();

create or replace function public.customer_payments_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('rms.invoice_paid', new.invoice_id::text, true);
  update public.invoices
     set amount_paid = (select coalesce(sum(amount), 0) from public.customer_payments where invoice_id = new.invoice_id and voided_at is null)
   where id = new.invoice_id;
  perform set_config('rms.invoice_paid', '', true);
  return null;
end $$;
create trigger customer_payments_after after insert or update on public.customer_payments
  for each row execute function public.customer_payments_after();

-- ---------------------------------------------------------------------------
-- Audit, attachments, grants and row-level security
-- ---------------------------------------------------------------------------

create trigger audit_invoices after insert or update or delete on public.invoices for each row execute function public.audit_trigger();
create trigger audit_invoice_lines after insert or update or delete on public.invoice_lines for each row execute function public.audit_trigger();
create trigger audit_customer_payments after insert or update or delete on public.customer_payments for each row execute function public.audit_trigger();

alter table public.attachments drop constraint attachments_entity_type_check;
alter table public.attachments add constraint attachments_entity_type_check
  check (entity_type in ('customer', 'opportunity', 'tender', 'quotation', 'quotation_revision', 'contract', 'project', 'invoice'));

create or replace function public.can_access_entity(p_entity_type text, p_write boolean) returns boolean
language sql stable security definer set search_path = public as $$
  select case p_entity_type
    when 'customer' then public.has_permission(case when p_write then 'customers.write' else 'customers.read' end)
    when 'opportunity' then public.has_permission(case when p_write then 'crm.write' else 'crm.read' end)
    when 'tender' then public.has_permission(case when p_write then 'tenders.write' else 'tenders.read' end)
    when 'quotation' then public.has_permission(case when p_write then 'quotations.write' else 'quotations.read' end)
    when 'quotation_revision' then public.has_permission(case when p_write then 'quotations.write' else 'quotations.read' end)
    when 'contract' then public.has_permission(case when p_write then 'quotations.award' else 'contracts.read' end)
    when 'project' then public.has_permission(case when p_write then 'quotations.award' else 'projects.read' end)
    when 'invoice' then public.has_permission(case when p_write then 'invoices.write' else 'invoices.read' end)
    else false end
$$;

grant select, insert, update, delete on public.invoices, public.invoice_lines, public.customer_payments to authenticated;
grant all on public.invoices, public.invoice_lines, public.customer_payments to service_role;
revoke delete, truncate on public.invoices, public.customer_payments from authenticated;
revoke execute on function public.recalculate_invoice(uuid) from public, anon, authenticated;
grant execute on function public.issue_invoice(uuid), public.cancel_invoice(uuid, text) to authenticated;
grant execute on function public.zatca_qr(text, text, timestamptz, numeric, numeric), public.zatca_tlv(integer, text) to authenticated;
revoke execute on function public.issue_invoice(uuid), public.cancel_invoice(uuid, text) from public, anon;

alter table public.invoices enable row level security;
alter table public.invoice_lines enable row level security;
alter table public.customer_payments enable row level security;

create policy invoices_select on public.invoices for select to authenticated using (public.has_permission('invoices.read'));
create policy invoices_insert on public.invoices for insert to authenticated with check (public.has_permission('invoices.write'));
create policy invoices_update on public.invoices for update to authenticated
  using (public.has_permission('invoices.write') or public.has_permission('invoices.issue'))
  with check (public.has_permission('invoices.write') or public.has_permission('invoices.issue'));

create policy invoice_lines_select on public.invoice_lines for select to authenticated using (public.has_permission('invoices.read'));
create policy invoice_lines_insert on public.invoice_lines for insert to authenticated with check (public.has_permission('invoices.write'));
create policy invoice_lines_update on public.invoice_lines for update to authenticated
  using (public.has_permission('invoices.write')) with check (public.has_permission('invoices.write'));
create policy invoice_lines_delete on public.invoice_lines for delete to authenticated using (public.has_permission('invoices.write'));

create policy customer_payments_select on public.customer_payments for select to authenticated using (public.has_permission('invoices.read'));
create policy customer_payments_insert on public.customer_payments for insert to authenticated with check (public.has_permission('payments.write'));
create policy customer_payments_update on public.customer_payments for update to authenticated
  using (public.has_permission('payments.write')) with check (public.has_permission('payments.write'));
