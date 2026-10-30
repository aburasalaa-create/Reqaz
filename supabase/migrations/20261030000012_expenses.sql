-- RMS expenses: money spent by the company or by a staff member (to be reimbursed), with the receipt attached.
--
-- Rules
--   * Amounts and VAT are typed from the receipt by a person; the system only adds them up.
--   * draft → submitted → approved | rejected → (approved) paid. Rejecting needs a comment.
--     Self-approval follows company_settings.allow_self_approval. Every change is in the audit log.
--   * Only drafts can be edited, and only by the person who entered them (or an approver).
--   * Receipts are attachments on the 'expense' entity.

create type public.expense_status as enum ('draft', 'submitted', 'approved', 'rejected', 'paid', 'cancelled');
create type public.expense_paid_by as enum ('company', 'employee');

insert into public.permissions (code, module, description) values
  ('expenses.read', 'expenses', 'View all expenses'),
  ('expenses.write', 'expenses', 'Record expenses'),
  ('expenses.approve', 'expenses', 'Approve, reject and mark expenses paid');

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on (
  (r.code in ('administrator', 'general_manager', 'finance') and p.code like 'expenses.%')
  or (r.code = 'project_management' and p.code like 'expenses.%')
  or (r.code in ('sales', 'estimation', 'site_engineering', 'procurement', 'document_control') and p.code = 'expenses.write'))
on conflict do nothing;

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  expense_date date not null default (now() at time zone 'Asia/Riyadh')::date,
  description text not null check (length(trim(description)) > 0),
  category text not null default 'general',
  supplier_id uuid references public.suppliers (id) on delete restrict,
  supplier_name text,
  supplier_vat_number text check (supplier_vat_number is null or supplier_vat_number ~ '^3\d{13}3$'),
  supplier_invoice_number text,
  project_id uuid references public.projects (id) on delete restrict,
  currency char(3) not null default 'SAR' references public.currencies (code),
  amount numeric(18, 2) not null check (amount >= 0),         -- before VAT, as printed on the receipt
  vat_amount numeric(18, 2) not null default 0 check (vat_amount >= 0),
  total_amount numeric(18, 2) generated always as (amount + vat_amount) stored,
  paid_by public.expense_paid_by not null default 'company',
  payment_method public.payment_method,
  notes text,
  status public.expense_status not null default 'draft',
  created_by uuid not null references public.app_users (id) default auth.uid(),
  submitted_at timestamptz,
  decided_by uuid references public.app_users (id),
  decided_at timestamptz,
  decision_comment text,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index expenses_status_idx on public.expenses (status, expense_date desc);
create index expenses_project_idx on public.expenses (project_id);
create trigger expenses_updated before update on public.expenses for each row execute function public.set_updated_at();

create or replace function public.expense_number() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.number := public.next_document_number('expense', 'EXP', true, 5);
  return new;
end $$;
create trigger expenses_number before insert on public.expenses for each row execute function public.expense_number();
create trigger expenses_number_fixed before update on public.expenses for each row execute function public.protect_number('number');

create or replace function public.expenses_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_approver boolean := public.has_permission('expenses.approve');
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then raise exception 'Expenses start as drafts' using errcode = 'check_violation'; end if;
    new.created_by := coalesce(auth.uid(), new.created_by);
    new.submitted_at := null; new.decided_by := null; new.decided_at := null; new.paid_at := null;
    return new;
  end if;
  if new.created_by <> old.created_by then raise exception 'The author cannot change' using errcode = 'check_violation'; end if;
  if old.status <> 'draft'
     and (new.expense_date, new.description, new.category, new.supplier_id, new.supplier_name, new.supplier_vat_number,
          new.supplier_invoice_number, new.project_id, new.currency, new.amount, new.vat_amount, new.paid_by, new.notes)
         is distinct from
         (old.expense_date, old.description, old.category, old.supplier_id, old.supplier_name, old.supplier_vat_number,
          old.supplier_invoice_number, old.project_id, old.currency, old.amount, old.vat_amount, old.paid_by, old.notes) then
    raise exception 'Only draft expenses can be edited' using errcode = 'insufficient_privilege';
  end if;
  if new.status = old.status then return new; end if;

  if old.status = 'draft' and new.status = 'submitted' then
    if new.supplier_id is null and coalesce(trim(new.supplier_name), '') = '' then
      raise exception 'Enter who was paid' using errcode = 'check_violation';
    end if;
    new.submitted_at := now();
  elsif old.status = 'submitted' and new.status = 'draft' then
    if auth.uid() <> old.created_by then raise exception 'Only the author can withdraw an expense' using errcode = 'insufficient_privilege'; end if;
    new.submitted_at := null;
  elsif old.status = 'submitted' and new.status in ('approved', 'rejected') then
    if not v_approver then raise exception 'You do not have permission to approve expenses' using errcode = 'insufficient_privilege'; end if;
    if auth.uid() = old.created_by and not coalesce((select allow_self_approval from public.company_settings), false) then
      raise exception 'An expense must be approved by someone other than its author' using errcode = 'insufficient_privilege';
    end if;
    if new.status = 'rejected' and length(trim(coalesce(new.decision_comment, ''))) = 0 then
      raise exception 'A comment is required when rejecting' using errcode = 'check_violation';
    end if;
    new.decided_by := auth.uid(); new.decided_at := now();
  elsif old.status = 'approved' and new.status = 'paid' then
    if not v_approver then raise exception 'You do not have permission to mark expenses paid' using errcode = 'insufficient_privilege'; end if;
    new.paid_at := now();
  elsif old.status in ('draft', 'submitted', 'rejected') and new.status = 'cancelled' then
    if auth.uid() <> old.created_by and not v_approver then
      raise exception 'Only the author or an approver can cancel' using errcode = 'insufficient_privilege';
    end if;
  else
    raise exception 'Invalid expense status change from % to %', old.status, new.status using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger expenses_guard before insert or update on public.expenses for each row execute function public.expenses_guard();
create trigger audit_expenses after insert or update on public.expenses for each row execute function public.audit_trigger();

alter table public.attachments drop constraint attachments_entity_type_check;
alter table public.attachments add constraint attachments_entity_type_check
  check (entity_type in ('customer', 'opportunity', 'tender', 'quotation', 'quotation_revision', 'contract', 'project', 'invoice',
                         'purchase_request', 'purchase_order', 'expense'));

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
    -- Which expense rows a person sees is decided by the expenses policies; see the attachment policies below.
    when 'expense' then public.has_permission('expenses.write') or public.has_permission('expenses.read')
    else false end
$$;

grant select, insert, update on public.expenses to authenticated;
grant all on public.expenses to service_role;

alter table public.expenses enable row level security;
create policy expenses_select on public.expenses for select to authenticated
  using (public.has_permission('expenses.read') or (created_by = auth.uid() and public.has_permission('expenses.write')));
create policy expenses_insert on public.expenses for insert to authenticated with check (public.has_permission('expenses.write'));
create policy expenses_update on public.expenses for update to authenticated
  using ((created_by = auth.uid() and public.has_permission('expenses.write')) or public.has_permission('expenses.approve'))
  with check ((created_by = auth.uid() and public.has_permission('expenses.write')) or public.has_permission('expenses.approve'));

-- Receipts are visible and changeable only with their expense: the subquery runs under the expenses row-level security.
drop policy attachments_select on public.attachments;
drop policy attachments_insert on public.attachments;
drop policy attachments_update on public.attachments;
create policy attachments_select on public.attachments for select to authenticated
  using (public.can_access_entity(entity_type, false)
         and (entity_type <> 'expense' or exists (select 1 from public.expenses e where e.id = entity_id)));
create policy attachments_insert on public.attachments for insert to authenticated
  with check (public.can_access_entity(entity_type, true) and uploaded_by = auth.uid()
              and (entity_type <> 'expense' or exists (select 1 from public.expenses e where e.id = entity_id and e.status = 'draft')));
create policy attachments_update on public.attachments for update to authenticated
  using (public.can_access_entity(entity_type, true)
         and (entity_type <> 'expense' or exists (select 1 from public.expenses e where e.id = entity_id and e.status = 'draft')))
  with check (public.can_access_entity(entity_type, true));
