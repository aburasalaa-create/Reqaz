-- RMS approvals by value, incoming customer purchase orders, project budgets, budget changes and variations.
--
-- Approvals
--   * approval_levels lists, per document type, the amount from which a level applies and the role that signs it.
--     A document needs every level whose minimum is at or below its amount, in order. With no levels configured a single
--     approval by anyone with the approve permission is enough (the original behaviour).
--   * Administrators and general managers can sign any level.
--   * company_settings.segregation_of_duties: when on, nobody approves their own document and each level needs a
--     different person, whatever allow_self_approval says.
--   * Every submission, approval, rejection and return is kept in approval_history.
--
-- Customer purchase orders (orders received from Reqaz customers)
--   received → under_review → clarification_required ⇄ under_review → accepted | rejected
--   accepted → active (project conversion: creates the contract and project, or links to the existing one)
--   active → completed → closed. Before acceptance an order can be cancelled.
--   Amendments point at the order they replace; activating the amendment marks the original superseded.
--   The order's lines and amounts can change only before acceptance.
--
-- Project budgets
--   * A project's approved budget is the sum of its budget lines (one per cost category). The amount from the awarded
--     quotation starts in "Not yet allocated".
--   * Budgets change only through an approved budget change or an approved variation, never because a purchase order
--     was raised.

-- ---------------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------------

insert into public.permissions (code, module, description) values
  ('customer_pos.read', 'customer_pos', 'View purchase orders received from customers'),
  ('customer_pos.write', 'customer_pos', 'Register and review customer purchase orders'),
  ('customer_pos.accept', 'customer_pos', 'Accept or reject customer purchase orders and convert them to projects'),
  ('budgets.write', 'projects', 'Request project budget changes and variations'),
  ('budgets.approve', 'projects', 'Approve project budget changes and variations');

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on (
  (r.code in ('administrator', 'general_manager') and p.code in ('customer_pos.read', 'customer_pos.write', 'customer_pos.accept', 'budgets.write', 'budgets.approve'))
  or (r.code = 'sales' and p.code in ('customer_pos.read', 'customer_pos.write'))
  or (r.code in ('finance', 'estimation') and p.code = 'customer_pos.read')
  or (r.code = 'project_management' and p.code in ('customer_pos.read', 'budgets.write')))
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Approval levels and history
-- ---------------------------------------------------------------------------

alter table public.company_settings add column segregation_of_duties boolean not null default false;

create table public.approval_levels (
  id uuid primary key default gen_random_uuid(),
  doc_type text not null check (doc_type in ('purchase_request', 'purchase_order', 'customer_po', 'budget_change', 'variation', 'supplier_invoice')),
  level integer not null check (level between 1 and 9),
  min_amount numeric(18, 2) not null default 0 check (min_amount >= 0),
  role_id uuid references public.roles (id) on delete restrict,   -- null: anyone with the approve permission
  created_at timestamptz not null default now(),
  unique (doc_type, level)
);

create table public.approval_history (
  id bigint generated always as identity primary key,
  doc_type text not null,
  doc_id uuid not null,
  level integer,
  action text not null check (action in ('submitted', 'approved', 'rejected', 'returned', 'cancelled')),
  actor_id uuid references public.app_users (id) default auth.uid(),
  amount numeric(18, 2),
  comment text,
  created_at timestamptz not null default now()
);
create index approval_history_doc_idx on public.approval_history (doc_type, doc_id, id);

create or replace function public.approval_history_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'Approval history cannot be changed' using errcode = 'insufficient_privilege';
end $$;
create trigger approval_history_immutable before update or delete on public.approval_history
  for each row execute function public.approval_history_immutable();

create or replace function public.record_approval_event(p_doc_type text, p_doc_id uuid, p_action text, p_amount numeric, p_comment text)
returns void
language sql security definer set search_path = public as $$
  insert into public.approval_history (doc_type, doc_id, action, amount, comment) values (p_doc_type, p_doc_id, p_action, p_amount, p_comment);
$$;

-- Levels a document of this amount needs (level 0 = a single approval when nothing is configured).
create or replace function public.required_approval_levels(p_doc_type text, p_amount numeric)
returns table (level integer, role_id uuid, min_amount numeric)
language sql stable security definer set search_path = public as $$
  select l.level, l.role_id, l.min_amount from public.approval_levels l
   where l.doc_type = p_doc_type and l.min_amount <= coalesce(p_amount, 0)
  union all
  select 0, null::uuid, 0::numeric
   where not exists (select 1 from public.approval_levels l where l.doc_type = p_doc_type and l.min_amount <= coalesce(p_amount, 0))
  order by 1
$$;

-- Approvals given since the document was last submitted.
create or replace function public.current_approvals(p_doc_type text, p_doc_id uuid)
returns table (level integer, actor_id uuid)
language sql stable security definer set search_path = public as $$
  select h.level, h.actor_id from public.approval_history h
   where h.doc_type = p_doc_type and h.doc_id = p_doc_id and h.action = 'approved'
     and h.id > coalesce((select max(id) from public.approval_history s where s.doc_type = p_doc_type and s.doc_id = p_doc_id
                           and s.action in ('submitted', 'returned', 'rejected')), 0)
$$;

-- Record one approval or rejection by the current user. Returns true when the document is now fully approved.
create or replace function public.decide_approval(p_doc_type text, p_doc_id uuid, p_amount numeric, p_requester uuid,
                                                  p_permission text, p_approve boolean, p_comment text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  s public.company_settings%rowtype;
  v_level record;
  v_senior boolean;
begin
  if not public.has_permission(p_permission) then
    raise exception 'You do not have permission to approve this' using errcode = 'insufficient_privilege';
  end if;
  select * into s from public.company_settings;
  if v_uid = p_requester and (s.segregation_of_duties or not coalesce(s.allow_self_approval, false)) then
    raise exception 'This must be approved by someone other than the person who raised it' using errcode = 'insufficient_privilege';
  end if;
  if not p_approve then
    if length(trim(coalesce(p_comment, ''))) = 0 then
      raise exception 'A reason is required when rejecting' using errcode = 'check_violation';
    end if;
    insert into public.approval_history (doc_type, doc_id, action, amount, comment) values (p_doc_type, p_doc_id, 'rejected', p_amount, p_comment);
    return false;
  end if;

  select r.* into v_level from public.required_approval_levels(p_doc_type, p_amount) r
   where r.level not in (select a.level from public.current_approvals(p_doc_type, p_doc_id) a)
   order by r.level limit 1;
  if not found then return true; end if;

  v_senior := exists (select 1 from public.user_roles ur join public.roles ro on ro.id = ur.role_id
                       where ur.user_id = v_uid and ro.code in ('administrator', 'general_manager'));
  if v_level.role_id is not null and not v_senior
     and not exists (select 1 from public.user_roles ur where ur.user_id = v_uid and ur.role_id = v_level.role_id) then
    raise exception 'Approval level % needs the % role', v_level.level, (select name_en from public.roles where id = v_level.role_id)
      using errcode = 'insufficient_privilege';
  end if;
  if s.segregation_of_duties and exists (select 1 from public.current_approvals(p_doc_type, p_doc_id) a where a.actor_id = v_uid) then
    raise exception 'You have already approved this at another level; a different person must approve the next level'
      using errcode = 'insufficient_privilege';
  end if;
  insert into public.approval_history (doc_type, doc_id, level, action, amount, comment)
  values (p_doc_type, p_doc_id, v_level.level, 'approved', p_amount, p_comment);

  return not exists (select 1 from public.required_approval_levels(p_doc_type, p_amount) r
                      where r.level not in (select a.level from public.current_approvals(p_doc_type, p_doc_id) a));
end $$;

revoke all on function public.record_approval_event(text, uuid, text, numeric, text), public.decide_approval(text, uuid, numeric, uuid, text, boolean, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Project budgets
-- ---------------------------------------------------------------------------

create table public.project_budget_lines (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete restrict,
  cost_category text not null references public.cost_categories (code),
  amount numeric(18, 2) not null default 0 check (amount >= 0),
  updated_at timestamptz not null default now(),
  unique (project_id, cost_category)
);

-- Only the budget functions below may change budget lines or a project's approved budget.
create or replace function public.project_budget_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('rms.budget', true), '') <> coalesce(new.project_id, old.project_id)::text then
    raise exception 'Project budgets change only through an approved budget change or variation' using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end $$;
create trigger project_budget_lines_guard before insert or update or delete on public.project_budget_lines
  for each row execute function public.project_budget_lines_guard();

create or replace function public.projects_budget_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.approved_budget is distinct from old.approved_budget and coalesce(current_setting('rms.budget', true), '') <> new.id::text then
    raise exception 'Project budgets change only through an approved budget change or variation' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger projects_budget_guard before update on public.projects for each row execute function public.projects_budget_guard();

-- Add a (signed) amount to a budget line and keep the project's approved budget equal to the sum of its lines.
create or replace function public.apply_budget_delta(p_project_id uuid, p_category text, p_delta numeric) returns void
language plpgsql security definer set search_path = public as $$
declare v_amt numeric;
begin
  perform set_config('rms.budget', p_project_id::text, true);
  insert into public.project_budget_lines (project_id, cost_category, amount) values (p_project_id, p_category, 0)
  on conflict (project_id, cost_category) do nothing;
  update public.project_budget_lines set amount = amount + p_delta, updated_at = now()
   where project_id = p_project_id and cost_category = p_category returning amount into v_amt;
  if v_amt < 0 then
    raise exception 'The % budget cannot go below zero', (select name_en from public.cost_categories where code = p_category) using errcode = 'check_violation';
  end if;
  update public.projects set approved_budget = (select coalesce(sum(amount), 0) from public.project_budget_lines where project_id = p_project_id)
   where id = p_project_id;
  perform set_config('rms.budget', '', true);
end $$;
revoke all on function public.apply_budget_delta(uuid, text, numeric) from public, anon, authenticated;

create or replace function public.projects_initial_budget() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('rms.budget', new.id::text, true);
  insert into public.project_budget_lines (project_id, cost_category, amount) values (new.id, 'general', new.approved_budget);
  perform set_config('rms.budget', '', true);
  return null;
end $$;
create trigger projects_initial_budget after insert on public.projects for each row execute function public.projects_initial_budget();

-- Existing projects: their approved budget becomes the "Not yet allocated" line.
do $$
declare p record;
begin
  for p in select id, approved_budget from public.projects loop
    perform set_config('rms.budget', p.id::text, true);
    insert into public.project_budget_lines (project_id, cost_category, amount) values (p.id, 'general', p.approved_budget)
    on conflict do nothing;
  end loop;
  perform set_config('rms.budget', '', true);
end $$;

-- Project status (planning → active → on_hold ⇄ active → completed → closed; cancelled before completion).
create or replace function public.set_project_status(p_project_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare v_old text;
begin
  if not (public.has_permission('budgets.write') or public.has_permission('customer_pos.accept')) then
    raise exception 'You do not have permission to change the project status' using errcode = 'insufficient_privilege';
  end if;
  select status into v_old from public.projects where id = p_project_id for update;
  if not found then raise exception 'Project not found' using errcode = 'no_data_found'; end if;
  if v_old = p_status then return; end if;
  if not ((v_old = 'planning' and p_status in ('active', 'cancelled')) or (v_old = 'active' and p_status in ('on_hold', 'completed', 'cancelled'))
          or (v_old = 'on_hold' and p_status in ('active', 'cancelled')) or (v_old = 'completed' and p_status in ('closed', 'active'))) then
    raise exception 'A % project cannot become %', v_old, p_status using errcode = 'check_violation';
  end if;
  update public.projects set status = p_status where id = p_project_id;
  perform public.log_event('projects', p_project_id::text, v_old || ' → ' || p_status);
end $$;

-- Budget changes: draft → submitted → approved | rejected (approval levels apply); draft | submitted → cancelled.
create table public.budget_changes (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  project_id uuid not null references public.projects (id) on delete restrict,
  variation_id uuid,                                  -- set when created by an approved variation
  reason text not null check (length(trim(reason)) > 0),
  status text not null default 'draft' check (status in ('draft', 'submitted', 'approved', 'rejected', 'cancelled')),
  total_change numeric(18, 2) not null default 0,
  requested_by uuid not null references public.app_users (id) default auth.uid(),
  submitted_at timestamptz,
  decided_by uuid references public.app_users (id),
  decided_at timestamptz,
  decision_comment text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index budget_changes_project_idx on public.budget_changes (project_id);
create trigger budget_changes_updated before update on public.budget_changes for each row execute function public.set_updated_at();

create table public.budget_change_lines (
  id uuid primary key default gen_random_uuid(),
  change_id uuid not null references public.budget_changes (id) on delete cascade,
  cost_category text not null references public.cost_categories (code),
  amount numeric(18, 2) not null check (amount <> 0),  -- + increase, − decrease or move out
  note text
);

create or replace function public.budget_change_number() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.number := public.next_document_number('budget_change', 'BC', true, 4);
  return new;
end $$;
create trigger budget_changes_number before insert on public.budget_changes for each row execute function public.budget_change_number();
create trigger budget_changes_number_fixed before update on public.budget_changes for each row execute function public.protect_number('number');

create or replace function public.budget_change_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_status text; v_id uuid := coalesce(new.change_id, old.change_id);
begin
  select status into v_status from public.budget_changes where id = v_id;
  if v_status <> 'draft' and coalesce(current_setting('rms.budget_change', true), '') <> v_id::text then
    raise exception 'Only draft budget changes can be edited' using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end $$;
create trigger budget_change_lines_guard before insert or update or delete on public.budget_change_lines
  for each row execute function public.budget_change_lines_guard();

create or replace function public.budget_change_lines_total() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce(new.change_id, old.change_id);
begin
  perform set_config('rms.budget_change_calc', v_id::text, true);
  update public.budget_changes set total_change = (select coalesce(sum(amount), 0) from public.budget_change_lines where change_id = v_id) where id = v_id;
  perform set_config('rms.budget_change_calc', '', true);
  return null;
end $$;
create trigger budget_change_lines_total after insert or update or delete on public.budget_change_lines
  for each row execute function public.budget_change_lines_total();

create or replace function public.budget_changes_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_done boolean; l record; v_abs numeric;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' and coalesce(current_setting('rms.budget_change', true), '') <> 'variation' then
      raise exception 'Budget changes start as drafts' using errcode = 'check_violation';
    end if;
    new.requested_by := coalesce(auth.uid(), new.requested_by); new.total_change := 0;
    return new;
  end if;
  if new.total_change is distinct from old.total_change and coalesce(current_setting('rms.budget_change_calc', true), '') <> new.id::text then
    raise exception 'The total is calculated from the lines' using errcode = 'insufficient_privilege';
  end if;
  if (new.project_id, new.requested_by, new.variation_id) is distinct from (old.project_id, old.requested_by, old.variation_id) then
    raise exception 'The project and requester cannot change' using errcode = 'check_violation';
  end if;
  if old.status <> 'draft' and new.reason is distinct from old.reason then
    raise exception 'Only draft budget changes can be edited' using errcode = 'insufficient_privilege';
  end if;
  if new.status = old.status then return new; end if;
  select sum(abs(amount)) into v_abs from public.budget_change_lines where change_id = new.id;

  if old.status = 'draft' and new.status = 'submitted' then
    if v_abs is null then raise exception 'Add at least one budget line' using errcode = 'check_violation'; end if;
    new.submitted_at := now();
    perform public.record_approval_event('budget_change', new.id, 'submitted', v_abs, null);
  elsif old.status = 'submitted' and new.status = 'draft' then
    if auth.uid() <> old.requested_by then raise exception 'Only the requester can withdraw' using errcode = 'insufficient_privilege'; end if;
    perform public.record_approval_event('budget_change', new.id, 'returned', v_abs, 'Withdrawn');
  elsif old.status = 'submitted' and new.status in ('approved', 'rejected') then
    v_done := public.decide_approval('budget_change', new.id, v_abs, old.requested_by, 'budgets.approve', new.status = 'approved', new.decision_comment);
    if new.status = 'approved' and not v_done then
      new.status := 'submitted';   -- more approval levels are still needed
      return new;
    end if;
    new.decided_by := auth.uid(); new.decided_at := now();
    if new.status = 'approved' then
      for l in select cost_category, sum(amount) as amount from public.budget_change_lines where change_id = new.id group by 1 order by sum(amount) loop
        perform public.apply_budget_delta(new.project_id, l.cost_category, l.amount);
      end loop;
    end if;
  elsif old.status in ('draft', 'submitted') and new.status = 'cancelled' then
    if auth.uid() <> old.requested_by and not public.has_permission('budgets.approve') then
      raise exception 'Only the requester or an approver can cancel' using errcode = 'insufficient_privilege';
    end if;
  else
    raise exception 'A % budget change cannot become %', old.status, new.status using errcode = 'check_violation';
  end if;
  perform public.log_event('budget_changes', new.id::text, old.status || ' → ' || new.status,
    case when new.decision_comment is not null then jsonb_build_object('comment', new.decision_comment) end);
  return new;
end $$;
create trigger budget_changes_guard before insert or update on public.budget_changes for each row execute function public.budget_changes_guard();

-- ---------------------------------------------------------------------------
-- Variations (change orders agreed with the customer)
-- ---------------------------------------------------------------------------

create table public.variations (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  project_id uuid not null references public.projects (id) on delete restrict,
  contract_id uuid not null references public.contracts (id) on delete restrict,
  title text not null check (length(trim(title)) > 0),
  description text,
  customer_reference text,                                    -- customer's instruction / VO number
  value numeric(18, 2) not null default 0,                    -- change to the contract value, excl. VAT (+ addition, − omission)
  cost_impact numeric(18, 2) not null default 0,              -- change to the project budget
  cost_category text not null default 'general' references public.cost_categories (code),
  status text not null default 'draft' check (status in ('draft', 'submitted', 'approved', 'rejected', 'cancelled')),
  requested_by uuid not null references public.app_users (id) default auth.uid(),
  submitted_at timestamptz,
  decided_by uuid references public.app_users (id),
  decided_at timestamptz,
  decision_comment text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index variations_project_idx on public.variations (project_id);
create trigger variations_updated before update on public.variations for each row execute function public.set_updated_at();
alter table public.budget_changes add constraint budget_changes_variation_fk foreign key (variation_id) references public.variations (id);

create or replace function public.variation_number() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.number := public.next_document_number('variation', 'VO', true, 4);
  new.contract_id := (select contract_id from public.projects where id = new.project_id);
  return new;
end $$;
create trigger variations_number before insert on public.variations for each row execute function public.variation_number();
create trigger variations_number_fixed before update on public.variations for each row execute function public.protect_number('number');

create or replace function public.variations_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_done boolean; v_amt numeric; v_bc uuid;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then raise exception 'Variations start as drafts' using errcode = 'check_violation'; end if;
    new.requested_by := coalesce(auth.uid(), new.requested_by);
    return new;
  end if;
  if (new.project_id, new.contract_id, new.requested_by) is distinct from (old.project_id, old.contract_id, old.requested_by) then
    raise exception 'The project cannot change' using errcode = 'check_violation';
  end if;
  if old.status <> 'draft' and (new.title, new.description, new.customer_reference, new.value, new.cost_impact, new.cost_category)
       is distinct from (old.title, old.description, old.customer_reference, old.value, old.cost_impact, old.cost_category) then
    raise exception 'Only draft variations can be edited' using errcode = 'insufficient_privilege';
  end if;
  if new.status = old.status then return new; end if;
  v_amt := greatest(abs(new.value), abs(new.cost_impact));

  if old.status = 'draft' and new.status = 'submitted' then
    if new.value = 0 and new.cost_impact = 0 then raise exception 'Enter the value or the cost impact' using errcode = 'check_violation'; end if;
    new.submitted_at := now();
    perform public.record_approval_event('variation', new.id, 'submitted', v_amt, null);
  elsif old.status = 'submitted' and new.status = 'draft' then
    if auth.uid() <> old.requested_by then raise exception 'Only the requester can withdraw' using errcode = 'insufficient_privilege'; end if;
    perform public.record_approval_event('variation', new.id, 'returned', v_amt, 'Withdrawn');
  elsif old.status = 'submitted' and new.status in ('approved', 'rejected') then
    v_done := public.decide_approval('variation', new.id, v_amt, old.requested_by, 'budgets.approve', new.status = 'approved', new.decision_comment);
    if new.status = 'approved' and not v_done then new.status := 'submitted'; return new; end if;
    new.decided_by := auth.uid(); new.decided_at := now();
    if new.status = 'approved' then
      if (select original_value + approved_variations_value from public.contracts where id = new.contract_id) + new.value < 0 then
        raise exception 'The contract value cannot go below zero' using errcode = 'check_violation';
      end if;
      update public.contracts set approved_variations_value = approved_variations_value + new.value where id = new.contract_id;
      if new.cost_impact <> 0 then
        perform set_config('rms.budget_change', 'variation', true);
        insert into public.budget_changes (project_id, variation_id, reason, status, requested_by, submitted_at, decided_by, decided_at)
        values (new.project_id, new.id, 'Variation ' || new.number || ': ' || new.title, 'approved', old.requested_by, now(), auth.uid(), now())
        returning id into v_bc;
        perform set_config('rms.budget_change', v_bc::text, true);
        insert into public.budget_change_lines (change_id, cost_category, amount) values (v_bc, new.cost_category, new.cost_impact);
        perform set_config('rms.budget_change', '', true);
        perform public.apply_budget_delta(new.project_id, new.cost_category, new.cost_impact);
      end if;
    end if;
  elsif old.status in ('draft', 'submitted') and new.status = 'cancelled' then
    if auth.uid() <> old.requested_by and not public.has_permission('budgets.approve') then
      raise exception 'Only the requester or an approver can cancel' using errcode = 'insufficient_privilege';
    end if;
  else
    raise exception 'A % variation cannot become %', old.status, new.status using errcode = 'check_violation';
  end if;
  perform public.log_event('variations', new.id::text, old.status || ' → ' || new.status,
    case when new.decision_comment is not null then jsonb_build_object('comment', new.decision_comment) end);
  return new;
end $$;
create trigger variations_guard before insert or update on public.variations for each row execute function public.variations_guard();

-- ---------------------------------------------------------------------------
-- Customer purchase orders
-- ---------------------------------------------------------------------------

create table public.customer_pos (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,                                 -- internal record ID, CPO-YYYY-NNNNN
  customer_po_number text not null check (length(trim(customer_po_number)) > 0),
  customer_id uuid not null references public.customers (id) on delete restrict,
  contact_id uuid references public.contacts (id) on delete set null,
  po_date date not null,
  received_date date not null default (now() at time zone 'Asia/Riyadh')::date,
  po_type text not null default 'original' check (po_type in ('original', 'amendment', 'supplementary', 'partial')),
  parent_id uuid references public.customer_pos (id) on delete restrict,   -- the order an amendment replaces
  opportunity_id uuid references public.opportunities (id) on delete restrict,
  quotation_id uuid references public.quotations (id) on delete restrict,
  quotation_revision_id uuid references public.quotation_revisions (id) on delete restrict,
  project_id uuid references public.projects (id) on delete restrict,
  contract_id uuid references public.contracts (id) on delete restrict,
  currency char(3) not null default 'SAR' references public.currencies (code),
  amount numeric(18, 2) not null default 0 check (amount >= 0),             -- excl. VAT, as on the customer's order
  vat_rate numeric(5, 2) not null default 15 check (vat_rate >= 0 and vat_rate < 100),
  vat_amount numeric(18, 2) not null default 0 check (vat_amount >= 0),     -- as stated on the order
  total_amount numeric(18, 2) generated always as (amount + vat_amount) stored,
  payment_terms text,
  delivery_date date,
  completion_date date,
  scope_notes text,
  responsible_user_id uuid references public.app_users (id) default auth.uid(),
  status text not null default 'received' check (status in ('received', 'under_review', 'clarification_required', 'accepted', 'rejected',
                                                            'active', 'completed', 'closed', 'cancelled', 'superseded')),
  status_note text,                                            -- clarification needed / rejection / cancellation reason
  reviewed_by uuid references public.app_users (id),
  reviewed_at timestamptz,
  accepted_by uuid references public.app_users (id),
  accepted_at timestamptz,
  activated_at timestamptz,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_pos_amendment check ((po_type = 'amendment') = (parent_id is not null)),
  constraint customer_pos_no_duplicates unique nulls not distinct (customer_id, customer_po_number, po_type, parent_id)
);
create index customer_pos_customer_idx on public.customer_pos (customer_id);
create index customer_pos_project_idx on public.customer_pos (project_id);
create index customer_pos_quotation_idx on public.customer_pos (quotation_id);
create index customer_pos_status_idx on public.customer_pos (status);
create trigger customer_pos_updated before update on public.customer_pos for each row execute function public.set_updated_at();

create table public.customer_po_lines (
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references public.customer_pos (id) on delete cascade,
  sort_order integer not null default 0,
  quotation_line_id uuid references public.quotation_lines (id) on delete set null,
  item_code text,
  description text not null check (length(trim(description)) > 0),
  unit text not null default 'LS',
  quantity numeric(18, 3) not null check (quantity > 0),
  unit_price numeric(18, 4) not null check (unit_price >= 0),
  amount numeric(18, 2) generated always as (round(quantity * unit_price, 2)) stored,
  created_at timestamptz not null default now()
);
create index customer_po_lines_po_idx on public.customer_po_lines (po_id, sort_order);

create or replace function public.customer_pos_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.customer_pos%rowtype; q public.quotations%rowtype;
begin
  new.number := public.next_document_number('customer_po', 'CPO', true, 5);
  if new.status <> 'received' then raise exception 'Customer orders are registered as received' using errcode = 'check_violation'; end if;
  new.reviewed_by := null; new.reviewed_at := null; new.accepted_by := null; new.accepted_at := null; new.activated_at := null;
  if new.parent_id is not null then
    select * into p from public.customer_pos where id = new.parent_id;
    if p.status not in ('accepted', 'active', 'completed') then
      raise exception 'Only an accepted or active order can be amended' using errcode = 'check_violation';
    end if;
    new.customer_id := p.customer_id;
    new.project_id := coalesce(new.project_id, p.project_id); new.contract_id := coalesce(new.contract_id, p.contract_id);
    new.quotation_id := coalesce(new.quotation_id, p.quotation_id); new.quotation_revision_id := coalesce(new.quotation_revision_id, p.quotation_revision_id);
    new.opportunity_id := coalesce(new.opportunity_id, p.opportunity_id);
  end if;
  if new.quotation_revision_id is not null then
    new.quotation_id := (select quotation_id from public.quotation_revisions where id = new.quotation_revision_id);
  end if;
  if new.quotation_id is not null then
    select * into q from public.quotations where id = new.quotation_id;
    if q.customer_id <> new.customer_id then
      raise exception 'The quotation belongs to another customer' using errcode = 'check_violation';
    end if;
    new.opportunity_id := q.opportunity_id;
    if new.quotation_revision_id is null then
      new.quotation_revision_id := coalesce(q.awarded_revision_id,
        (select id from public.quotation_revisions where quotation_id = q.id and status in ('approved', 'submitted', 'awarded')
          order by revision_no desc limit 1));
    end if;
  end if;
  if new.project_id is null and new.quotation_id is not null then
    -- Further orders against a quotation that already has a project go to that project.
    select p2.id, p2.contract_id into new.project_id, new.contract_id
      from public.contracts c join public.projects p2 on p2.contract_id = c.id where c.quotation_id = new.quotation_id;
  end if;
  if new.project_id is not null then
    new.contract_id := (select contract_id from public.projects where id = new.project_id);
    if (select customer_id from public.projects where id = new.project_id) <> new.customer_id then
      raise exception 'The project belongs to another customer' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;
create trigger customer_pos_before_insert before insert on public.customer_pos for each row execute function public.customer_pos_before_insert();
create trigger customer_pos_number_fixed before update on public.customer_pos for each row execute function public.protect_number('number');

create or replace function public.customer_po_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  select status into v_status from public.customer_pos where id = coalesce(new.po_id, old.po_id);
  if v_status not in ('received', 'under_review', 'clarification_required') then
    raise exception 'The order is % and its lines can no longer change; register an amendment', v_status using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end $$;
create trigger customer_po_lines_guard before insert or update or delete on public.customer_po_lines
  for each row execute function public.customer_po_lines_guard();

-- With lines, the order amount is their sum and VAT follows the rate (the person can still correct the VAT to what is printed).
create or replace function public.customer_po_lines_total() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_id uuid := coalesce(new.po_id, old.po_id); v_amt numeric;
begin
  select coalesce(sum(amount), 0) into v_amt from public.customer_po_lines where po_id = v_id;
  update public.customer_pos set amount = v_amt, vat_amount = round(v_amt * vat_rate / 100, 2) where id = v_id;
  return null;
end $$;
create trigger customer_po_lines_total after insert or update or delete on public.customer_po_lines
  for each row execute function public.customer_po_lines_total();

create or replace function public.customer_pos_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_done boolean; v_activate boolean := coalesce(current_setting('rms.cpo_activate', true), '') = new.id::text;
begin
  if (new.customer_id, new.po_type, new.parent_id, new.created_by) is distinct from (old.customer_id, old.po_type, old.parent_id, old.created_by) then
    raise exception 'The customer and order type cannot change' using errcode = 'check_violation';
  end if;
  if not v_activate and (new.project_id, new.contract_id, new.reviewed_by, new.reviewed_at, new.accepted_by, new.accepted_at, new.activated_at)
       is distinct from (old.project_id, old.contract_id, old.reviewed_by, old.reviewed_at, old.accepted_by, old.accepted_at, old.activated_at) then
    raise exception 'These details are set by the workflow' using errcode = 'insufficient_privilege';
  end if;
  if old.status not in ('received', 'under_review', 'clarification_required') and not v_activate
     and (new.customer_po_number, new.contact_id, new.po_date, new.quotation_id, new.quotation_revision_id, new.currency, new.amount,
          new.vat_rate, new.vat_amount, new.payment_terms, new.delivery_date, new.completion_date, new.scope_notes)
         is distinct from
         (old.customer_po_number, old.contact_id, old.po_date, old.quotation_id, old.quotation_revision_id, old.currency, old.amount,
          old.vat_rate, old.vat_amount, old.payment_terms, old.delivery_date, old.completion_date, old.scope_notes) then
    raise exception 'An accepted order cannot be changed; register an amendment' using errcode = 'insufficient_privilege';
  end if;
  if new.status = old.status then return new; end if;

  if old.status = 'received' and new.status = 'under_review' then
    new.reviewed_by := auth.uid(); new.reviewed_at := now();
    perform public.record_approval_event('customer_po', new.id, 'submitted', new.amount, null);
  elsif old.status = 'under_review' and new.status = 'clarification_required' then
    if length(trim(coalesce(new.status_note, ''))) = 0 then
      raise exception 'Describe what needs clarifying with the customer' using errcode = 'check_violation';
    end if;
    perform public.record_approval_event('customer_po', new.id, 'returned', new.amount, new.status_note);
  elsif old.status = 'clarification_required' and new.status = 'under_review' then
    perform public.record_approval_event('customer_po', new.id, 'submitted', new.amount, new.status_note);
  elsif old.status = 'under_review' and new.status in ('accepted', 'rejected') then
    if new.amount <= 0 then raise exception 'Enter the order amount before accepting' using errcode = 'check_violation'; end if;
    v_done := public.decide_approval('customer_po', new.id, new.amount, coalesce(old.reviewed_by, old.created_by), 'customer_pos.accept',
                                     new.status = 'accepted', new.status_note);
    if new.status = 'accepted' and not v_done then new.status := 'under_review'; return new; end if;
    if new.status = 'accepted' then new.accepted_by := auth.uid(); new.accepted_at := now(); end if;
  elsif old.status = 'accepted' and new.status = 'active' and v_activate then
    new.activated_at := now();
  elsif old.status = 'active' and new.status = 'completed' or old.status = 'completed' and new.status = 'closed' then
    if not public.has_permission('customer_pos.accept') then
      raise exception 'You do not have permission to close customer orders' using errcode = 'insufficient_privilege';
    end if;
  elsif old.status in ('received', 'under_review', 'clarification_required') and new.status = 'cancelled' then
    if length(trim(coalesce(new.status_note, ''))) = 0 then raise exception 'A reason is required' using errcode = 'check_violation'; end if;
  elsif old.status in ('active', 'completed', 'accepted') and new.status = 'superseded' and v_activate then
    null;
  else
    raise exception 'A % customer order cannot become %', replace(old.status, '_', ' '), replace(new.status, '_', ' ') using errcode = 'check_violation';
  end if;
  perform public.log_event('customer_pos', new.id::text, old.status || ' → ' || new.status,
    case when new.status_note is not null then jsonb_build_object('note', new.status_note) end);
  return new;
end $$;
create trigger customer_pos_guard before update on public.customer_pos for each row execute function public.customer_pos_guard();

-- Copy the quotation's priced lines into a new (still editable) customer order, so only the differences need typing.
create or replace function public.customer_po_copy_quotation(p_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare po public.customer_pos%rowtype; v_n integer;
begin
  if not public.has_permission('customer_pos.write') then
    raise exception 'You do not have permission to edit customer orders' using errcode = 'insufficient_privilege';
  end if;
  select * into po from public.customer_pos where id = p_id;
  if po.quotation_revision_id is null then raise exception 'Link the order to a quotation first' using errcode = 'check_violation'; end if;
  insert into public.customer_po_lines (po_id, sort_order, quotation_line_id, item_code, description, unit, quantity, unit_price)
  select p_id, sort_order, id, item_code, description_en, unit, quantity, sell_rate
    from public.quotation_lines where revision_id = po.quotation_revision_id and quantity > 0;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Project conversion: an accepted order creates the contract and project (from its quotation) or joins the existing project.
create or replace function public.convert_customer_po(p_id uuid, p_project_name text, p_project_manager_id uuid, p_start_date date,
                                                      p_target_completion_date date, p_retention_pct numeric default 0,
                                                      p_advance_payment_pct numeric default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare po public.customer_pos%rowtype; v_rev public.quotation_revisions%rowtype; v_res jsonb; v_project uuid; v_contract uuid;
begin
  if not public.has_permission('customer_pos.accept') then
    raise exception 'You do not have permission to convert customer orders' using errcode = 'insufficient_privilege';
  end if;
  select * into po from public.customer_pos where id = p_id for update;
  if not found then raise exception 'Customer order not found' using errcode = 'no_data_found'; end if;
  if po.status <> 'accepted' then
    raise exception 'The order must be accepted before it becomes a project (it is %)', replace(po.status, '_', ' ') using errcode = 'check_violation';
  end if;
  v_project := po.project_id; v_contract := po.contract_id;
  if v_project is null then
    if po.quotation_revision_id is null then
      raise exception 'Link the order to its quotation to create the contract and project' using errcode = 'check_violation';
    end if;
    select * into v_rev from public.quotation_revisions where id = po.quotation_revision_id for update;
    if v_rev.status = 'approved' then
      update public.quotation_revisions set status = 'submitted', submitted_to_client_by = auth.uid(), submitted_to_client_at = now()
       where id = v_rev.id;
    end if;
    v_res := public.award_quotation(po.quotation_revision_id, coalesce(nullif(trim(p_project_name), ''), po.scope_notes),
                                    coalesce(p_project_manager_id, po.responsible_user_id, auth.uid()),
                                    coalesce(p_start_date, po.po_date), coalesce(p_target_completion_date, po.completion_date, po.po_date + 90),
                                    po.po_date, p_retention_pct, p_advance_payment_pct);
    v_project := (v_res ->> 'project_id')::uuid; v_contract := (v_res ->> 'contract_id')::uuid;
  end if;
  perform set_config('rms.cpo_activate', p_id::text, true);
  update public.customer_pos set project_id = v_project, contract_id = v_contract, status = 'active' where id = p_id;
  if po.parent_id is not null then
    perform set_config('rms.cpo_activate', po.parent_id::text, true);
    update public.customer_pos set status = 'superseded' where id = po.parent_id;
  end if;
  perform set_config('rms.cpo_activate', '', true);
  if (select status from public.projects where id = v_project) = 'planning' then
    update public.projects set status = 'active' where id = v_project;
  end if;
  perform public.log_event('customer_pos', p_id::text, 'converted to project', jsonb_build_object('project_id', v_project, 'contract_id', v_contract));
  return jsonb_build_object('project_id', v_project, 'contract_id', v_contract);
end $$;

-- ---------------------------------------------------------------------------
-- Audit, attachments, grants and row-level security
-- ---------------------------------------------------------------------------

create trigger audit_customer_pos after insert or update on public.customer_pos for each row execute function public.audit_trigger();
create trigger audit_customer_po_lines after insert or update or delete on public.customer_po_lines for each row execute function public.audit_trigger();
create trigger audit_budget_changes after insert or update on public.budget_changes for each row execute function public.audit_trigger();
create trigger audit_variations after insert or update on public.variations for each row execute function public.audit_trigger();
create trigger audit_project_budget_lines after insert or update on public.project_budget_lines for each row execute function public.audit_trigger();
create trigger audit_approval_levels after insert or update or delete on public.approval_levels for each row execute function public.audit_trigger();

grant select, insert, update on public.customer_pos, public.budget_changes, public.variations to authenticated;
grant select, insert, update, delete on public.customer_po_lines, public.budget_change_lines to authenticated;
grant select on public.project_budget_lines, public.approval_history to authenticated;
grant select, insert, update, delete on public.approval_levels to authenticated;
grant all on public.customer_pos, public.customer_po_lines, public.budget_changes, public.budget_change_lines, public.variations,
  public.project_budget_lines, public.approval_levels, public.approval_history to service_role;
revoke execute on function public.customer_po_copy_quotation(uuid), public.set_project_status(uuid, text),
  public.convert_customer_po(uuid, text, uuid, date, date, numeric, numeric) from public, anon;
grant execute on function public.customer_po_copy_quotation(uuid), public.set_project_status(uuid, text),
  public.convert_customer_po(uuid, text, uuid, date, date, numeric, numeric) to authenticated;

alter table public.customer_pos enable row level security;
alter table public.customer_po_lines enable row level security;
alter table public.project_budget_lines enable row level security;
alter table public.budget_changes enable row level security;
alter table public.budget_change_lines enable row level security;
alter table public.variations enable row level security;
alter table public.approval_levels enable row level security;
alter table public.approval_history enable row level security;

create policy customer_pos_select on public.customer_pos for select to authenticated using (public.has_permission('customer_pos.read'));
create policy customer_pos_insert on public.customer_pos for insert to authenticated with check (public.has_permission('customer_pos.write'));
create policy customer_pos_update on public.customer_pos for update to authenticated
  using (public.has_permission('customer_pos.write') or public.has_permission('customer_pos.accept'))
  with check (public.has_permission('customer_pos.write') or public.has_permission('customer_pos.accept'));
create policy customer_po_lines_select on public.customer_po_lines for select to authenticated using (public.has_permission('customer_pos.read'));
create policy customer_po_lines_write on public.customer_po_lines for all to authenticated
  using (public.has_permission('customer_pos.write')) with check (public.has_permission('customer_pos.write'));

create policy project_budget_lines_select on public.project_budget_lines for select to authenticated
  using (public.has_permission('projects.read') or public.has_permission('budgets.write'));
create policy budget_changes_select on public.budget_changes for select to authenticated
  using (public.has_permission('projects.read') or public.has_permission('budgets.write'));
create policy budget_changes_insert on public.budget_changes for insert to authenticated with check (public.has_permission('budgets.write'));
create policy budget_changes_update on public.budget_changes for update to authenticated
  using ((requested_by = auth.uid() and public.has_permission('budgets.write')) or public.has_permission('budgets.approve'))
  with check ((requested_by = auth.uid() and public.has_permission('budgets.write')) or public.has_permission('budgets.approve'));
create policy budget_change_lines_select on public.budget_change_lines for select to authenticated
  using (public.has_permission('projects.read') or public.has_permission('budgets.write'));
create policy budget_change_lines_write on public.budget_change_lines for all to authenticated
  using (exists (select 1 from public.budget_changes c where c.id = change_id and c.requested_by = auth.uid()) and public.has_permission('budgets.write'))
  with check (exists (select 1 from public.budget_changes c where c.id = change_id and c.requested_by = auth.uid()) and public.has_permission('budgets.write'));
create policy variations_select on public.variations for select to authenticated
  using (public.has_permission('projects.read') or public.has_permission('budgets.write'));
create policy variations_insert on public.variations for insert to authenticated with check (public.has_permission('budgets.write'));
create policy variations_update on public.variations for update to authenticated
  using ((requested_by = auth.uid() and public.has_permission('budgets.write')) or public.has_permission('budgets.approve'))
  with check ((requested_by = auth.uid() and public.has_permission('budgets.write')) or public.has_permission('budgets.approve'));

create policy approval_levels_select on public.approval_levels for select to authenticated using (public.is_active_user());
create policy approval_levels_write on public.approval_levels for all to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));
create policy approval_history_select on public.approval_history for select to authenticated using (public.is_active_user());
