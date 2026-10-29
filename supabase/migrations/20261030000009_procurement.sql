-- RMS procurement: purchase requests (site/project needs, approved by a manager) and purchase orders to suppliers.
--
-- Rules
--   * A request is drafted, submitted, then approved or rejected by someone other than the requester.
--   * Purchase orders are drafts until issued. Issuing assigns the next gap-free PO number and freezes the supplier details.
--     Issued orders never change; they can only be cancelled (with a reason) or marked received/closed.
--   * Order totals are calculated only by public.recalculate_purchase_order() (same VAT method as invoices).

create type public.pr_status as enum ('draft', 'submitted', 'approved', 'rejected', 'ordered', 'cancelled');
create type public.po_status as enum ('draft', 'issued', 'received', 'closed', 'cancelled');

insert into public.permissions (code, module, description) values
  ('procurement.read', 'procurement', 'View purchase requests and purchase orders'),
  ('procurement.request', 'procurement', 'Raise purchase requests'),
  ('procurement.approve', 'procurement', 'Approve or reject purchase requests'),
  ('procurement.order', 'procurement', 'Prepare and issue purchase orders to suppliers');

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on (
  (r.code in ('administrator', 'general_manager') and p.code like 'procurement.%')
  or (r.code = 'procurement' and p.code in ('procurement.read', 'procurement.request', 'procurement.order'))
  or (r.code = 'project_management' and p.code in ('procurement.read', 'procurement.request', 'procurement.approve'))
  or (r.code = 'site_engineering' and p.code in ('procurement.read', 'procurement.request'))
  or (r.code = 'finance' and p.code = 'procurement.read'))
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Purchase requests
-- ---------------------------------------------------------------------------

create table public.purchase_requests (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  title text not null check (length(trim(title)) > 0),
  project_id uuid references public.projects (id) on delete restrict,
  needed_by date,
  delivery_location text,
  notes text,
  status public.pr_status not null default 'draft',
  requested_by uuid not null references public.app_users (id) default auth.uid(),
  submitted_at timestamptz,
  decided_by uuid references public.app_users (id),
  decided_at timestamptz,
  decision_comment text,
  estimated_total numeric(18, 2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index purchase_requests_status_idx on public.purchase_requests (status);
create trigger purchase_requests_updated before update on public.purchase_requests for each row execute function public.set_updated_at();

create table public.purchase_request_lines (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.purchase_requests (id) on delete cascade,
  sort_order integer not null default 0,
  description text not null check (length(trim(description)) > 0),
  unit text not null default 'EA',
  quantity numeric(18, 3) not null check (quantity > 0),
  estimated_unit_cost numeric(18, 4) not null default 0 check (estimated_unit_cost >= 0),
  estimated_total numeric(18, 2) generated always as (round(quantity * estimated_unit_cost, 2)) stored,
  created_at timestamptz not null default now()
);
create index purchase_request_lines_idx on public.purchase_request_lines (request_id, sort_order);

create or replace function public.pr_number() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.number := public.next_document_number('purchase_request', 'PR');
  return new;
end $$;
create trigger purchase_requests_number before insert on public.purchase_requests for each row execute function public.pr_number();
create trigger purchase_requests_number_fixed before update on public.purchase_requests for each row execute function public.protect_number('number');

-- Lines change only while the request is a draft; the estimate total follows the lines.
create or replace function public.pr_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_status public.pr_status;
begin
  select status into v_status from public.purchase_requests where id = coalesce(new.request_id, old.request_id);
  if v_status is distinct from 'draft' then
    raise exception 'Only draft purchase requests can be edited' using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end $$;
create trigger pr_lines_guard before insert or update or delete on public.purchase_request_lines
  for each row execute function public.pr_lines_guard();

create or replace function public.pr_lines_total() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce(new.request_id, old.request_id);
begin
  perform set_config('rms.pr_calc', v_id::text, true);
  update public.purchase_requests
     set estimated_total = (select coalesce(sum(estimated_total), 0) from public.purchase_request_lines where request_id = v_id)
   where id = v_id;
  perform set_config('rms.pr_calc', '', true);
  return null;
end $$;
create trigger pr_lines_total after insert or update or delete on public.purchase_request_lines
  for each row execute function public.pr_lines_total();

-- Status changes:
--   draft → submitted → approved | rejected      (decision by someone else with procurement.approve)
--   submitted → draft                            (requester withdraws)
--   draft | submitted | approved → cancelled
--   approved → ordered                           (only when a purchase order is created from it)
create or replace function public.purchase_requests_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_calc boolean := coalesce(current_setting('rms.pr_calc', true), '') = new.id::text;
        v_order boolean := coalesce(current_setting('rms.pr_order', true), '') = new.id::text;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then raise exception 'Purchase requests start as drafts' using errcode = 'check_violation'; end if;
    new.requested_by := coalesce(auth.uid(), new.requested_by);
    new.estimated_total := 0; new.submitted_at := null; new.decided_by := null; new.decided_at := null;
    return new;
  end if;
  if new.estimated_total is distinct from old.estimated_total and not v_calc then
    raise exception 'The estimate total is calculated from the lines' using errcode = 'insufficient_privilege';
  end if;
  if new.requested_by <> old.requested_by then
    raise exception 'The requester cannot change' using errcode = 'check_violation';
  end if;
  if old.status not in ('draft') and (new.title, new.project_id, new.needed_by, new.delivery_location, new.notes)
       is distinct from (old.title, old.project_id, old.needed_by, old.delivery_location, old.notes) then
    raise exception 'Only draft purchase requests can be edited' using errcode = 'insufficient_privilege';
  end if;
  if new.status = old.status then return new; end if;

  if old.status = 'draft' and new.status = 'submitted' then
    if not exists (select 1 from public.purchase_request_lines where request_id = new.id) then
      raise exception 'Add at least one item before submitting' using errcode = 'check_violation';
    end if;
    new.submitted_at := now();
  elsif old.status = 'submitted' and new.status = 'draft' then
    if auth.uid() <> old.requested_by then
      raise exception 'Only the requester can withdraw a request' using errcode = 'insufficient_privilege';
    end if;
    new.submitted_at := null;
  elsif old.status = 'submitted' and new.status in ('approved', 'rejected') then
    if not public.has_permission('procurement.approve') then
      raise exception 'You do not have permission to approve purchase requests' using errcode = 'insufficient_privilege';
    end if;
    if auth.uid() = old.requested_by then
      raise exception 'A purchase request must be approved by someone other than the requester' using errcode = 'insufficient_privilege';
    end if;
    if new.status = 'rejected' and length(trim(coalesce(new.decision_comment, ''))) = 0 then
      raise exception 'A comment is required when rejecting' using errcode = 'check_violation';
    end if;
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
create trigger purchase_requests_guard before insert or update on public.purchase_requests
  for each row execute function public.purchase_requests_guard();

-- ---------------------------------------------------------------------------
-- Purchase orders
-- ---------------------------------------------------------------------------

create table public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  number text unique,                                    -- assigned on issue
  status public.po_status not null default 'draft',
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  purchase_request_id uuid references public.purchase_requests (id) on delete restrict,
  project_id uuid references public.projects (id) on delete restrict,
  currency char(3) not null default 'SAR' references public.currencies (code),
  supplier_quote_ref text,
  delivery_date date,
  delivery_address text,
  payment_terms text,
  terms text,
  notes text,
  subtotal numeric(18, 2) not null default 0,
  discount_total numeric(18, 2) not null default 0,
  taxable_amount numeric(18, 2) not null default 0,
  vat_total numeric(18, 2) not null default 0,
  total_amount numeric(18, 2) not null default 0,
  issued_at timestamptz,
  issue_date date,
  issued_by uuid references public.app_users (id),
  supplier_snapshot jsonb,
  buyer_snapshot jsonb,
  pdf_attachment_id uuid references public.attachments (id),
  status_changed_at timestamptz,
  cancel_reason text,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index purchase_orders_supplier_idx on public.purchase_orders (supplier_id);
create index purchase_orders_pr_idx on public.purchase_orders (purchase_request_id);
create trigger purchase_orders_updated before update on public.purchase_orders for each row execute function public.set_updated_at();

create table public.purchase_order_lines (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.purchase_orders (id) on delete cascade,
  sort_order integer not null default 0,
  item_code text,
  description text not null check (length(trim(description)) > 0),
  unit text not null default 'EA',
  quantity numeric(18, 3) not null check (quantity > 0),
  unit_price numeric(18, 4) not null default 0 check (unit_price >= 0),
  discount_amount numeric(18, 2) not null default 0 check (discount_amount >= 0),
  vat_code text not null default 'S15' references public.vat_codes (code),
  vat_rate numeric(5, 2) not null default 15,
  vat_category char(1) not null default 'S',
  gross_amount numeric(18, 2) generated always as (round(quantity * unit_price, 2)) stored,
  net_amount numeric(18, 2) generated always as (round(quantity * unit_price, 2) - discount_amount) stored,
  vat_amount numeric(18, 2) generated always as (round((round(quantity * unit_price, 2) - discount_amount) * vat_rate / 100, 2)) stored,
  created_at timestamptz not null default now(),
  constraint purchase_order_lines_discount check (discount_amount <= round(quantity * unit_price, 2))
);
create index purchase_order_lines_idx on public.purchase_order_lines (order_id, sort_order);

create or replace function public.po_lines_vat() returns trigger
language plpgsql security definer set search_path = public as $$
declare v public.vat_codes%rowtype;
begin
  select * into v from public.vat_codes where code = new.vat_code and is_active;
  if not found then raise exception 'Unknown VAT code %', new.vat_code using errcode = 'check_violation'; end if;
  new.vat_rate := v.rate; new.vat_category := v.zatca_category;
  return new;
end $$;
create trigger po_lines_vat before insert or update of vat_code on public.purchase_order_lines
  for each row execute function public.po_lines_vat();

create or replace function public.po_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_status public.po_status;
begin
  select status into v_status from public.purchase_orders where id = coalesce(new.order_id, old.order_id);
  if v_status is distinct from 'draft' then
    raise exception 'Only draft purchase orders can be edited' using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end $$;
create trigger po_lines_guard before insert or update or delete on public.purchase_order_lines
  for each row execute function public.po_lines_guard();

create or replace function public.recalculate_purchase_order(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_sub numeric; v_disc numeric; v_net numeric; v_vat numeric;
begin
  if (select status from public.purchase_orders where id = p_id) is distinct from 'draft' then return; end if;
  select coalesce(sum(gross_amount), 0), coalesce(sum(discount_amount), 0), coalesce(sum(net_amount), 0)
    into v_sub, v_disc, v_net from public.purchase_order_lines where order_id = p_id;
  select coalesce(sum(c), 0) into v_vat from (
    select round(sum(net_amount) * vat_rate / 100, 2) as c from public.purchase_order_lines where order_id = p_id group by vat_category, vat_rate) x;
  perform set_config('rms.po_calc', p_id::text, true);
  update public.purchase_orders set subtotal = v_sub, discount_total = v_disc, taxable_amount = v_net, vat_total = v_vat,
         total_amount = v_net + v_vat where id = p_id;
  perform set_config('rms.po_calc', '', true);
end $$;
revoke execute on function public.recalculate_purchase_order(uuid) from public, anon, authenticated;

create or replace function public.po_lines_recalc() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.recalculate_purchase_order(coalesce(new.order_id, old.order_id));
  return null;
end $$;
create trigger po_lines_recalc after insert or update or delete on public.purchase_order_lines
  for each row execute function public.po_lines_recalc();

-- Status: draft → issued → received → closed; draft | issued → cancelled (with reason). Issue only via issue_purchase_order().
create or replace function public.purchase_orders_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_calc boolean := coalesce(current_setting('rms.po_calc', true), '') = new.id::text;
        v_issue boolean := coalesce(current_setting('rms.po_issue', true), '') = new.id::text;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' or new.number is not null then
      raise exception 'Purchase orders are created as drafts' using errcode = 'check_violation';
    end if;
    new.subtotal := 0; new.discount_total := 0; new.taxable_amount := 0; new.vat_total := 0; new.total_amount := 0;
    new.issued_at := null; new.issued_by := null; new.supplier_snapshot := null; new.buyer_snapshot := null;
    return new;
  end if;
  if v_issue then return new; end if;
  if not v_calc and (new.subtotal, new.discount_total, new.taxable_amount, new.vat_total, new.total_amount)
       is distinct from (old.subtotal, old.discount_total, old.taxable_amount, old.vat_total, old.total_amount) then
    raise exception 'Order totals are calculated by the system' using errcode = 'insufficient_privilege';
  end if;
  if (new.number, new.issued_at, new.issue_date, new.issued_by, new.supplier_snapshot, new.buyer_snapshot, new.purchase_request_id)
       is distinct from (old.number, old.issued_at, old.issue_date, old.issued_by, old.supplier_snapshot, old.buyer_snapshot, old.purchase_request_id) then
    raise exception 'Issue details are set by the system' using errcode = 'insufficient_privilege';
  end if;
  if old.status <> 'draft' then
    -- Issued orders: only the status may move forward (and the archived PDF be linked once).
    if (to_jsonb(new) - 'status' - 'status_changed_at' - 'cancel_reason' - 'pdf_attachment_id' - 'updated_at')
       <> (to_jsonb(old) - 'status' - 'status_changed_at' - 'cancel_reason' - 'pdf_attachment_id' - 'updated_at')
       or (old.pdf_attachment_id is not null and new.pdf_attachment_id is distinct from old.pdf_attachment_id) then
      raise exception 'An issued purchase order cannot be changed; cancel it and issue a new one' using errcode = 'insufficient_privilege';
    end if;
  end if;
  if new.status <> old.status then
    if new.status = 'issued' then
      raise exception 'Use the issue action' using errcode = 'insufficient_privilege';
    elsif not ((old.status = 'issued' and new.status = 'received') or (old.status = 'received' and new.status = 'closed')
               or (old.status in ('draft', 'issued') and new.status = 'cancelled')) then
      raise exception 'A % purchase order cannot become %', old.status, new.status using errcode = 'check_violation';
    end if;
    if new.status = 'cancelled' and length(trim(coalesce(new.cancel_reason, ''))) = 0 then
      raise exception 'A reason is required to cancel a purchase order' using errcode = 'check_violation';
    end if;
    new.status_changed_at := now();
    perform public.log_event('purchase_orders', new.id::text, old.status || ' → ' || new.status,
      case when new.cancel_reason is not null then jsonb_build_object('reason', new.cancel_reason) end);
  end if;
  return new;
end $$;
create trigger purchase_orders_guard before insert or update on public.purchase_orders
  for each row execute function public.purchase_orders_guard();

-- Create a draft order from an approved request: copies the items (estimated cost as the starting price) and marks the request ordered.
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
  insert into public.purchase_orders (supplier_id, project_id, delivery_date, delivery_address)
  values (p_supplier_id, r.project_id, r.needed_by, r.delivery_location) returning id into v_id;
  perform set_config('rms.po_issue', v_id::text, true);
  update public.purchase_orders set purchase_request_id = r.id where id = v_id;
  perform set_config('rms.po_issue', '', true);
  insert into public.purchase_order_lines (order_id, sort_order, description, unit, quantity, unit_price)
  select v_id, sort_order, description, unit, quantity, estimated_unit_cost from public.purchase_request_lines where request_id = r.id;
  perform set_config('rms.pr_order', r.id::text, true);
  update public.purchase_requests set status = 'ordered' where id = r.id;
  perform set_config('rms.pr_order', '', true);
  return v_id;
end $$;

create or replace function public.issue_purchase_order(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare po public.purchase_orders%rowtype; su public.suppliers%rowtype; co public.company_settings%rowtype; v_now timestamptz := now();
begin
  if not public.has_permission('procurement.order') then
    raise exception 'You do not have permission to issue purchase orders' using errcode = 'insufficient_privilege';
  end if;
  select * into po from public.purchase_orders where id = p_id for update;
  if not found then raise exception 'Purchase order not found' using errcode = 'no_data_found'; end if;
  if po.status <> 'draft' then raise exception 'This purchase order is already %', po.status using errcode = 'check_violation'; end if;
  if not exists (select 1 from public.purchase_order_lines where order_id = p_id) then
    raise exception 'Add at least one line before issuing' using errcode = 'check_violation';
  end if;
  if po.total_amount <= 0 then raise exception 'The order total must be more than zero' using errcode = 'check_violation'; end if;
  select * into su from public.suppliers where id = po.supplier_id;
  if not su.is_active then raise exception 'The supplier is inactive' using errcode = 'check_violation'; end if;
  select * into co from public.company_settings;
  perform set_config('rms.po_issue', p_id::text, true);
  update public.purchase_orders
     set status = 'issued', number = public.next_document_number('purchase_order', 'PO', true, 5),
         issued_at = v_now, issue_date = (v_now at time zone 'Asia/Riyadh')::date, issued_by = auth.uid(), status_changed_at = v_now,
         supplier_snapshot = to_jsonb(su) - 'notes' - 'created_by' - 'created_at' - 'updated_at',
         buyer_snapshot = to_jsonb(co) - 'id' - 'updated_at' - 'allow_self_approval' - 'quotation_validity_days' - 'bank_accounts'
   where id = p_id;
  perform set_config('rms.po_issue', '', true);
  perform public.log_event('purchase_orders', p_id::text, 'issued');
end $$;

-- ---------------------------------------------------------------------------
-- Audit, attachments, grants and row-level security
-- ---------------------------------------------------------------------------

create trigger audit_purchase_requests after insert or update on public.purchase_requests for each row execute function public.audit_trigger();
create trigger audit_purchase_orders after insert or update on public.purchase_orders for each row execute function public.audit_trigger();
create trigger audit_purchase_order_lines after insert or update or delete on public.purchase_order_lines for each row execute function public.audit_trigger();

alter table public.attachments drop constraint attachments_entity_type_check;
alter table public.attachments add constraint attachments_entity_type_check
  check (entity_type in ('customer', 'opportunity', 'tender', 'quotation', 'quotation_revision', 'contract', 'project', 'invoice',
                         'purchase_request', 'purchase_order'));

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
    when 'purchase_request' then public.has_permission(case when p_write then 'procurement.request' else 'procurement.read' end)
    when 'purchase_order' then public.has_permission(case when p_write then 'procurement.order' else 'procurement.read' end)
    else false end
$$;

grant select, insert, update, delete on public.purchase_requests, public.purchase_request_lines,
  public.purchase_orders, public.purchase_order_lines to authenticated;
grant all on public.purchase_requests, public.purchase_request_lines, public.purchase_orders, public.purchase_order_lines to service_role;
revoke delete, truncate on public.purchase_requests, public.purchase_orders from authenticated;
revoke execute on function public.order_from_request(uuid, uuid), public.issue_purchase_order(uuid) from public, anon;
grant execute on function public.order_from_request(uuid, uuid), public.issue_purchase_order(uuid) to authenticated;

alter table public.purchase_requests enable row level security;
alter table public.purchase_request_lines enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_lines enable row level security;

create policy purchase_requests_select on public.purchase_requests for select to authenticated using (public.has_permission('procurement.read'));
create policy purchase_requests_insert on public.purchase_requests for insert to authenticated with check (public.has_permission('procurement.request'));
-- Requesters edit their own; approvers decide on any. Buyers change requests only through order_from_request().
create policy purchase_requests_update on public.purchase_requests for update to authenticated
  using ((public.has_permission('procurement.request') and requested_by = auth.uid()) or public.has_permission('procurement.approve'))
  with check ((public.has_permission('procurement.request') and requested_by = auth.uid()) or public.has_permission('procurement.approve'));

create policy purchase_request_lines_select on public.purchase_request_lines for select to authenticated using (public.has_permission('procurement.read'));
create policy purchase_request_lines_write on public.purchase_request_lines for all to authenticated
  using (exists (select 1 from public.purchase_requests r where r.id = request_id and r.requested_by = auth.uid()) and public.has_permission('procurement.request'))
  with check (exists (select 1 from public.purchase_requests r where r.id = request_id and r.requested_by = auth.uid()) and public.has_permission('procurement.request'));

create policy purchase_orders_select on public.purchase_orders for select to authenticated using (public.has_permission('procurement.read'));
create policy purchase_orders_insert on public.purchase_orders for insert to authenticated with check (public.has_permission('procurement.order'));
create policy purchase_orders_update on public.purchase_orders for update to authenticated
  using (public.has_permission('procurement.order')) with check (public.has_permission('procurement.order'));

create policy purchase_order_lines_select on public.purchase_order_lines for select to authenticated using (public.has_permission('procurement.read'));
create policy purchase_order_lines_write on public.purchase_order_lines for all to authenticated
  using (public.has_permission('procurement.order')) with check (public.has_permission('procurement.order'));
