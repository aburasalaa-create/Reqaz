-- RMS Phase 1: estimating (BOQ), quotations with controlled revisions and approvals,
-- and award into contract + project.

create type public.pricing_method as enum ('markup', 'margin');
create type public.discount_type as enum ('none', 'percent', 'amount');
create type public.quotation_status as enum ('open', 'won', 'lost', 'cancelled');
create type public.revision_status as enum ('draft', 'pending_approval', 'approved', 'submitted', 'superseded', 'awarded');

-- ---------------------------------------------------------------------------
-- Templates
-- ---------------------------------------------------------------------------

create table public.boq_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  is_active boolean not null default true,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.boq_template_items (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.boq_templates (id) on delete cascade,
  sort_order integer not null default 0,
  section text,
  item_code text,
  description_en text not null,
  description_ar text,
  unit text not null default 'LS',
  quantity numeric(18, 3) not null default 1 check (quantity >= 0),
  material_unit_cost numeric(18, 4) not null default 0 check (material_unit_cost >= 0),
  labour_unit_cost numeric(18, 4) not null default 0 check (labour_unit_cost >= 0),
  equipment_unit_cost numeric(18, 4) not null default 0 check (equipment_unit_cost >= 0),
  subcontract_unit_cost numeric(18, 4) not null default 0 check (subcontract_unit_cost >= 0),
  other_unit_cost numeric(18, 4) not null default 0 check (other_unit_cost >= 0)
);
create index boq_template_items_template_idx on public.boq_template_items (template_id, sort_order);

create table public.quotation_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  scope_en text, scope_ar text,
  exclusions_en text, exclusions_ar text,
  payment_terms_en text, payment_terms_ar text,
  completion_period_en text, completion_period_ar text,
  overhead_pct numeric(7, 3) not null default 10 check (overhead_pct between 0 and 100),
  contingency_pct numeric(7, 3) not null default 5 check (contingency_pct between 0 and 100),
  pricing_method public.pricing_method not null default 'markup',
  markup_pct numeric(7, 3) not null default 15 check (markup_pct between 0 and 1000),
  target_margin_pct numeric(7, 3) not null default 15 check (target_margin_pct >= 0 and target_margin_pct < 100),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Quotations
-- ---------------------------------------------------------------------------

create table public.quotations (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  opportunity_id uuid not null references public.opportunities (id) on delete restrict,
  tender_id uuid references public.tenders (id) on delete restrict,
  customer_id uuid not null references public.customers (id) on delete restrict,
  title text not null check (length(trim(title)) > 0),
  currency char(3) not null default 'SAR' references public.currencies (code),
  status public.quotation_status not null default 'open',
  awarded_revision_id uuid,
  lost_reason text,
  closed_at timestamptz,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint quotations_lost_reason check (status <> 'lost' or length(trim(coalesce(lost_reason, ''))) > 0)
);
create index quotations_opp_idx on public.quotations (opportunity_id);
create index quotations_customer_idx on public.quotations (customer_id);

create table public.quotation_revisions (
  id uuid primary key default gen_random_uuid(),
  quotation_id uuid not null references public.quotations (id) on delete restrict,
  revision_no integer not null check (revision_no >= 0),
  status public.revision_status not null default 'draft',

  -- Commercial terms shown to the client
  attention_contact_id uuid references public.contacts (id) on delete set null,
  subject text,
  valid_until date,
  scope_en text, scope_ar text,
  exclusions_en text, exclusions_ar text,
  payment_terms_en text, payment_terms_ar text,
  completion_period_en text, completion_period_ar text,
  internal_notes text,

  -- Pricing parameters
  exchange_rate_to_base numeric(18, 8) not null default 1 check (exchange_rate_to_base > 0),
  overhead_pct numeric(7, 3) not null default 10 check (overhead_pct between 0 and 100),
  contingency_pct numeric(7, 3) not null default 5 check (contingency_pct between 0 and 100),
  pricing_method public.pricing_method not null default 'markup',
  markup_pct numeric(7, 3) not null default 15 check (markup_pct between 0 and 1000),
  target_margin_pct numeric(7, 3) not null default 15 check (target_margin_pct >= 0 and target_margin_pct < 100),
  discount_type public.discount_type not null default 'none',
  discount_value numeric(18, 4) not null default 0 check (discount_value >= 0),
  vat_code text not null default 'S15' references public.vat_codes (code),
  vat_rate numeric(5, 2) not null default 15 check (vat_rate >= 0 and vat_rate < 100),

  -- Calculated by public.recalculate_revision(); never written by clients.
  material_cost numeric(18, 2) not null default 0,
  labour_cost numeric(18, 2) not null default 0,
  equipment_cost numeric(18, 2) not null default 0,
  subcontract_cost numeric(18, 2) not null default 0,
  other_cost numeric(18, 2) not null default 0,
  direct_cost numeric(18, 2) not null default 0,
  overhead_amount numeric(18, 2) not null default 0,
  contingency_amount numeric(18, 2) not null default 0,
  total_cost numeric(18, 2) not null default 0,
  target_price numeric(18, 2) not null default 0,
  price_factor numeric(20, 10) not null default 0,
  subtotal numeric(18, 2) not null default 0,
  discount_amount numeric(18, 2) not null default 0,
  net_amount numeric(18, 2) not null default 0,
  vat_amount numeric(18, 2) not null default 0,
  total_amount numeric(18, 2) not null default 0,
  gross_profit numeric(18, 2) not null default 0,
  gross_margin_pct numeric(9, 2),

  -- Workflow
  prepared_by uuid references public.app_users (id) default auth.uid(),
  submitted_for_approval_by uuid references public.app_users (id),
  submitted_for_approval_at timestamptz,
  approved_by uuid references public.app_users (id),
  approved_at timestamptz,
  submitted_to_client_by uuid references public.app_users (id),
  submitted_to_client_at timestamptz,
  client_pdf_attachment_id uuid references public.attachments (id),
  workflow_comment text,      -- transient: copied into quotation_approvals by trigger

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (quotation_id, revision_no)
);
create index quotation_revisions_status_idx on public.quotation_revisions (status);
-- At most one editable or in-approval revision per quotation.
create unique index quotation_revisions_one_open on public.quotation_revisions (quotation_id)
  where status in ('draft', 'pending_approval');

alter table public.quotations
  add constraint quotations_awarded_revision_fk foreign key (awarded_revision_id)
  references public.quotation_revisions (id);

create table public.quotation_lines (
  id uuid primary key default gen_random_uuid(),
  revision_id uuid not null references public.quotation_revisions (id) on delete cascade,
  sort_order integer not null default 0,
  section text,
  item_code text,
  description_en text not null check (length(trim(description_en)) > 0),
  description_ar text,
  unit text not null default 'LS',
  quantity numeric(18, 3) not null default 1 check (quantity >= 0),
  material_unit_cost numeric(18, 4) not null default 0 check (material_unit_cost >= 0),
  labour_unit_cost numeric(18, 4) not null default 0 check (labour_unit_cost >= 0),
  equipment_unit_cost numeric(18, 4) not null default 0 check (equipment_unit_cost >= 0),
  subcontract_unit_cost numeric(18, 4) not null default 0 check (subcontract_unit_cost >= 0),
  other_unit_cost numeric(18, 4) not null default 0 check (other_unit_cost >= 0),
  unit_cost numeric(18, 4) generated always as (
    material_unit_cost + labour_unit_cost + equipment_unit_cost + subcontract_unit_cost + other_unit_cost
  ) stored,
  material_amount numeric(18, 2) generated always as (round(quantity * material_unit_cost, 2)) stored,
  labour_amount numeric(18, 2) generated always as (round(quantity * labour_unit_cost, 2)) stored,
  equipment_amount numeric(18, 2) generated always as (round(quantity * equipment_unit_cost, 2)) stored,
  subcontract_amount numeric(18, 2) generated always as (round(quantity * subcontract_unit_cost, 2)) stored,
  other_amount numeric(18, 2) generated always as (round(quantity * other_unit_cost, 2)) stored,
  cost_total numeric(18, 2) generated always as (
    round(quantity * material_unit_cost, 2) + round(quantity * labour_unit_cost, 2)
    + round(quantity * equipment_unit_cost, 2) + round(quantity * subcontract_unit_cost, 2)
    + round(quantity * other_unit_cost, 2)
  ) stored,
  sell_rate numeric(18, 2) not null default 0,     -- calculated
  sell_total numeric(18, 2) not null default 0,    -- calculated
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index quotation_lines_revision_idx on public.quotation_lines (revision_id, sort_order);

create table public.quotation_approvals (
  id bigint generated always as identity primary key,
  revision_id uuid not null references public.quotation_revisions (id) on delete cascade,
  from_status public.revision_status not null,
  to_status public.revision_status not null,
  actor_id uuid default auth.uid(),
  comment text,
  created_at timestamptz not null default now()
);
create index quotation_approvals_revision_idx on public.quotation_approvals (revision_id);

-- ---------------------------------------------------------------------------
-- Contracts and projects (Phase 1 creates them on award; Phase 2 extends them)
-- ---------------------------------------------------------------------------

create table public.contracts (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  customer_id uuid not null references public.customers (id) on delete restrict,
  opportunity_id uuid not null references public.opportunities (id) on delete restrict,
  quotation_id uuid not null unique references public.quotations (id) on delete restrict,
  quotation_revision_id uuid not null unique references public.quotation_revisions (id) on delete restrict,
  title text not null,
  currency char(3) not null references public.currencies (code),
  exchange_rate_to_base numeric(18, 8) not null,
  original_value numeric(18, 2) not null check (original_value >= 0),      -- excl. VAT, from the awarded revision
  approved_variations_value numeric(18, 2) not null default 0,
  vat_rate numeric(5, 2) not null,
  retention_pct numeric(5, 2) not null default 0 check (retention_pct between 0 and 100),
  advance_payment_pct numeric(5, 2) not null default 0 check (advance_payment_pct between 0 and 100),
  signed_date date,
  status text not null default 'active' check (status in ('active', 'completed', 'terminated')),
  -- Frozen copy of the awarded revision and its lines (approved scope, pricing, terms).
  awarded_snapshot jsonb not null,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  contract_id uuid not null unique references public.contracts (id) on delete restrict,
  customer_id uuid not null references public.customers (id) on delete restrict,
  name text not null check (length(trim(name)) > 0),
  project_manager_id uuid not null references public.app_users (id),
  start_date date not null,
  target_completion_date date not null,
  approved_budget numeric(18, 2) not null check (approved_budget >= 0),
  status text not null default 'planning' check (status in ('planning', 'active', 'on_hold', 'completed', 'closed', 'cancelled')),
  location text,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint projects_dates check (target_completion_date >= start_date)
);

create trigger quotations_number before insert on public.quotations for each row execute function public.assign_number();
create trigger contracts_number before insert on public.contracts for each row execute function public.assign_number();
create trigger projects_number before insert on public.projects for each row execute function public.assign_number();
create trigger quotations_number_fixed before update on public.quotations for each row execute function public.protect_number('number');
create trigger contracts_number_fixed before update on public.contracts for each row execute function public.protect_number('number');
create trigger projects_number_fixed before update on public.projects for each row execute function public.protect_number('number');

-- The awarded snapshot and original contract value never change after award.
create or replace function public.contracts_guard() returns trigger
language plpgsql as $$
begin
  if new.awarded_snapshot <> old.awarded_snapshot
     or new.original_value <> old.original_value
     or new.quotation_revision_id <> old.quotation_revision_id
     or new.customer_id <> old.customer_id then
    raise exception 'The awarded scope and contract value are frozen; record a variation instead'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger contracts_guard before update on public.contracts for each row execute function public.contracts_guard();

-- ---------------------------------------------------------------------------
-- Pricing engine (authoritative). Mirrored in packages/shared/src/pricing.ts for
-- live previews; tests assert both produce identical results.
--
--   line amount(c)   = round(qty × unit cost(c), 2)        for each cost category c
--   direct cost      = Σ line amounts
--   overhead         = round(direct × overhead% , 2)
--   contingency      = round((direct + overhead) × contingency%, 2)
--   total cost       = direct + overhead + contingency
--   target price     = markup: round(total cost × (1 + markup%), 2)
--                      margin: round(total cost ÷ (1 − margin%), 2)
--   price factor     = round(round(target price ÷ direct cost, 20), 10)  (0 when direct cost is 0)
--   line sell rate   = round(line unit cost × factor, 2)
--   line sell total  = round(qty × sell rate, 2)
--   subtotal         = Σ line sell totals
--   discount         = percent: round(subtotal × d%, 2); amount: min(d, subtotal)
--   net              = subtotal − discount
--   VAT              = round(net × VAT%, 2)
--   total            = net + VAT
--   gross profit     = net − total cost; margin% = round(gross profit ÷ net × 100, 2)
-- Rounding is half away from zero (PostgreSQL numeric round()).
-- ---------------------------------------------------------------------------

create or replace function public.recalculate_revision(p_revision_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.quotation_revisions%rowtype;
  v_mat numeric; v_lab numeric; v_eqp numeric; v_sub numeric; v_oth numeric;
  v_direct numeric; v_oh numeric; v_cont numeric; v_cost numeric;
  v_target numeric; v_factor numeric; v_subtotal numeric; v_disc numeric;
  v_net numeric; v_vat numeric; v_gp numeric;
begin
  select * into r from public.quotation_revisions where id = p_revision_id for update;
  if not found or r.status <> 'draft' then
    return;
  end if;
  perform set_config('rms.recalc', p_revision_id::text, true);

  select coalesce(sum(material_amount), 0), coalesce(sum(labour_amount), 0), coalesce(sum(equipment_amount), 0),
         coalesce(sum(subcontract_amount), 0), coalesce(sum(other_amount), 0)
    into v_mat, v_lab, v_eqp, v_sub, v_oth
  from public.quotation_lines where revision_id = p_revision_id;

  v_direct := v_mat + v_lab + v_eqp + v_sub + v_oth;
  v_oh := round(v_direct * r.overhead_pct / 100, 2);
  v_cont := round((v_direct + v_oh) * r.contingency_pct / 100, 2);
  v_cost := v_direct + v_oh + v_cont;
  if r.pricing_method = 'markup' then
    v_target := round(v_cost * (1 + r.markup_pct / 100), 2);
  else
    v_target := round(v_cost / (1 - r.target_margin_pct / 100), 2);
  end if;
  -- Dividend cast to scale 20 makes the intermediate quotient scale deterministic (20 dp).
  v_factor := case when v_direct > 0 then round(v_target::numeric(38, 20) / v_direct, 10) else 0 end;

  update public.quotation_lines
     set sell_rate = round(unit_cost * v_factor, 2),
         sell_total = round(quantity * round(unit_cost * v_factor, 2), 2)
   where revision_id = p_revision_id
     and (sell_rate, sell_total) is distinct from (round(unit_cost * v_factor, 2), round(quantity * round(unit_cost * v_factor, 2), 2));

  select coalesce(sum(sell_total), 0) into v_subtotal from public.quotation_lines where revision_id = p_revision_id;

  v_disc := case r.discount_type
              when 'percent' then round(v_subtotal * least(r.discount_value, 100) / 100, 2)
              when 'amount' then least(round(r.discount_value, 2), v_subtotal)
              else 0 end;
  v_net := v_subtotal - v_disc;
  v_vat := round(v_net * r.vat_rate / 100, 2);
  v_gp := v_net - v_cost;

  update public.quotation_revisions set
    material_cost = v_mat, labour_cost = v_lab, equipment_cost = v_eqp,
    subcontract_cost = v_sub, other_cost = v_oth,
    direct_cost = v_direct, overhead_amount = v_oh, contingency_amount = v_cont, total_cost = v_cost,
    target_price = v_target, price_factor = v_factor,
    subtotal = v_subtotal, discount_amount = v_disc, net_amount = v_net,
    vat_amount = v_vat, total_amount = v_net + v_vat,
    gross_profit = v_gp,
    gross_margin_pct = case when v_net > 0 then round(v_gp / v_net * 100, 2) else null end
  where id = p_revision_id;
  perform set_config('rms.recalc', '', true);
end $$;
revoke all on function public.recalculate_revision(uuid) from public;

-- Lines can only change while their revision is a draft.
create or replace function public.quotation_lines_guard() returns trigger
language plpgsql as $$
declare
  v_status public.revision_status;
begin
  select status into v_status from public.quotation_revisions
   where id = case when tg_op = 'DELETE' then old.revision_id else new.revision_id end;
  if v_status is distinct from 'draft' then
    raise exception 'Revision is % and can no longer be edited; create a new revision', v_status
      using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE' and new.revision_id <> old.revision_id then
    raise exception 'Lines cannot move between revisions' using errcode = 'check_violation';
  end if;
  -- Sell rates are produced by the pricing engine only.
  if tg_op = 'INSERT' then
    new.sell_rate := 0;
    new.sell_total := 0;
  elsif tg_op = 'UPDATE'
        and (new.sell_rate, new.sell_total) is distinct from (old.sell_rate, old.sell_total)
        and coalesce(current_setting('rms.recalc', true), '') <> new.revision_id::text then
    raise exception 'Sell rates are calculated and cannot be written directly' using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end $$;
create trigger quotation_lines_guard before insert or update or delete on public.quotation_lines
  for each row execute function public.quotation_lines_guard();

create or replace function public.quotation_lines_recalc() returns trigger
language plpgsql as $$
begin
  perform public.recalculate_revision(coalesce(new.revision_id, old.revision_id));
  return null;
end $$;
create trigger quotation_lines_recalc
  after insert or delete or update of quantity, material_unit_cost, labour_unit_cost, equipment_unit_cost,
    subcontract_unit_cost, other_unit_cost on public.quotation_lines
  for each row execute function public.quotation_lines_recalc();

create or replace function public.quotation_revision_params_recalc() returns trigger
language plpgsql as $$
begin
  perform public.recalculate_revision(new.id);
  return null;
end $$;
create trigger quotation_revision_params_recalc
  after update of overhead_pct, contingency_pct, pricing_method, markup_pct, target_margin_pct,
    discount_type, discount_value, vat_rate on public.quotation_revisions
  for each row execute function public.quotation_revision_params_recalc();

-- ---------------------------------------------------------------------------
-- Revision workflow state machine
--   draft → pending_approval → approved → submitted → awarded
--   pending_approval → draft                (rejected by approver, or withdrawn by submitter)
--   approved | submitted → superseded       (when a later revision is submitted to the client)
-- ---------------------------------------------------------------------------

create or replace function public.quotation_revision_workflow() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_workflow_keys text[] := array['status', 'submitted_for_approval_by', 'submitted_for_approval_at',
    'approved_by', 'approved_at', 'submitted_to_client_by', 'submitted_to_client_at',
    'client_pdf_attachment_id', 'workflow_comment', 'updated_at'];
  v_calc_keys text[] := array['material_cost', 'labour_cost', 'equipment_cost', 'subcontract_cost', 'other_cost',
    'direct_cost', 'overhead_amount', 'contingency_amount', 'total_cost', 'target_price', 'price_factor',
    'subtotal', 'discount_amount', 'net_amount', 'vat_amount', 'total_amount', 'gross_profit', 'gross_margin_pct'];
  v_uid uuid := auth.uid();
  v_lines integer;
  v_self_ok boolean;
  v_comment text := nullif(trim(coalesce(new.workflow_comment, '')), '');
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'New revisions start as draft' using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if new.quotation_id <> old.quotation_id or new.revision_no <> old.revision_no or new.prepared_by is distinct from old.prepared_by then
    raise exception 'Revision identity cannot change' using errcode = 'check_violation';
  end if;

  if new.status = old.status then
    -- Content edits are only allowed on drafts. Calculated columns may only be changed by the engine
    -- (it runs as the definer inside recalculate_revision and only on drafts).
    if old.status <> 'draft'
       and (to_jsonb(new) - v_workflow_keys) <> (to_jsonb(old) - v_workflow_keys) then
      raise exception 'Revision is % and can no longer be edited; create a new revision', old.status
        using errcode = 'check_violation';
    end if;
    if coalesce(current_setting('rms.recalc', true), '') <> new.id::text
       and exists (select 1 from jsonb_each(to_jsonb(new)) n
                   where n.key = any (v_calc_keys) and n.value is distinct from to_jsonb(old) -> n.key) then
      raise exception 'Calculated totals cannot be written directly' using errcode = 'insufficient_privilege';
    end if;
    new.workflow_comment := null;
    return new;
  end if;

  -- Status transitions: no content changes allowed in the same statement.
  if (to_jsonb(new) - v_workflow_keys) <> (to_jsonb(old) - v_workflow_keys) then
    raise exception 'Change the status separately from the revision content' using errcode = 'check_violation';
  end if;

  if old.status = 'draft' and new.status = 'pending_approval' then
    if not public.has_permission('quotations.write') then
      raise exception 'Not permitted to submit quotations for approval' using errcode = 'insufficient_privilege';
    end if;
    select count(*) into v_lines from public.quotation_lines where revision_id = new.id;
    if v_lines = 0 or new.net_amount <= 0 then
      raise exception 'A quotation needs at least one priced line before approval' using errcode = 'check_violation';
    end if;
    if new.valid_until is null or new.valid_until < (now() at time zone 'Asia/Riyadh')::date then
      raise exception 'Set a validity date in the future before approval' using errcode = 'check_violation';
    end if;
    new.submitted_for_approval_by := v_uid;
    new.submitted_for_approval_at := now();

  elsif old.status = 'pending_approval' and new.status = 'draft' then
    if not (public.has_permission('quotations.approve')
            or (v_uid = old.submitted_for_approval_by and public.has_permission('quotations.write'))) then
      raise exception 'Not permitted to return this quotation to draft' using errcode = 'insufficient_privilege';
    end if;
    if v_uid <> old.submitted_for_approval_by and v_comment is null then
      raise exception 'A comment is required when rejecting a quotation' using errcode = 'check_violation';
    end if;
    new.submitted_for_approval_by := null;
    new.submitted_for_approval_at := null;

  elsif old.status = 'pending_approval' and new.status = 'approved' then
    if not public.has_permission('quotations.approve') then
      raise exception 'Not permitted to approve quotations' using errcode = 'insufficient_privilege';
    end if;
    select allow_self_approval into v_self_ok from public.company_settings;
    if not coalesce(v_self_ok, false)
       and (v_uid = old.prepared_by or v_uid = old.submitted_for_approval_by) then
      raise exception 'A quotation must be approved by someone other than its preparer' using errcode = 'insufficient_privilege';
    end if;
    new.approved_by := v_uid;
    new.approved_at := now();

  elsif old.status = 'approved' and new.status = 'submitted' then
    if not public.has_permission('quotations.submit') then
      raise exception 'Not permitted to submit quotations to clients' using errcode = 'insufficient_privilege';
    end if;
    if (select status from public.quotations where id = new.quotation_id) <> 'open' then
      raise exception 'The quotation is closed' using errcode = 'check_violation';
    end if;
    new.submitted_to_client_by := v_uid;
    new.submitted_to_client_at := now();

  elsif old.status in ('approved', 'submitted') and new.status = 'superseded' then
    if not exists (select 1 from public.quotation_revisions o
                   where o.quotation_id = new.quotation_id and o.revision_no > new.revision_no
                     and o.status = 'submitted') then
      raise exception 'Only a later submitted revision can supersede this one' using errcode = 'check_violation';
    end if;

  elsif old.status = 'submitted' and new.status = 'awarded' then
    if not public.has_permission('quotations.award') then
      raise exception 'Not permitted to award quotations' using errcode = 'insufficient_privilege';
    end if;

  else
    raise exception 'Invalid quotation status change from % to %', old.status, new.status
      using errcode = 'check_violation';
  end if;

  insert into public.quotation_approvals (revision_id, from_status, to_status, actor_id, comment)
  values (new.id, old.status, new.status, v_uid, v_comment);
  new.workflow_comment := null;
  return new;
end $$;

create trigger quotation_revisions_workflow before insert or update on public.quotation_revisions
  for each row execute function public.quotation_revision_workflow();

-- Move the pipeline forward (never backward) to reflect quotation progress.
create or replace function public.advance_opportunity(p_opportunity_id uuid, p_stage public.opportunity_stage)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.opportunities
     set stage = p_stage
   where id = p_opportunity_id
     and stage < p_stage
     and stage not in ('won', 'lost');
end $$;
revoke all on function public.advance_opportunity(uuid, public.opportunity_stage) from public;

create or replace function public.quotation_revision_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_opp uuid;
  v_tender uuid;
begin
  if new.status = old.status then
    return null;
  end if;
  select opportunity_id, tender_id into v_opp, v_tender from public.quotations where id = new.quotation_id;

  if new.status = 'pending_approval' then
    perform public.advance_opportunity(v_opp, 'internal_review');
  elsif new.status = 'submitted' then
    update public.quotation_revisions
       set status = 'superseded'
     where quotation_id = new.quotation_id and revision_no < new.revision_no
       and status in ('approved', 'submitted');
    perform public.advance_opportunity(v_opp, 'quotation_submitted');
    if v_tender is not null then
      update public.tenders set status = 'submitted'
       where id = v_tender and status in ('received', 'under_review', 'estimating');
    end if;
  end if;
  return null;
end $$;
create trigger quotation_revisions_after after update of status on public.quotation_revisions
  for each row execute function public.quotation_revision_after();

-- Quotation header: closed quotations are frozen; won/lost only through the functions below.
create or replace function public.quotations_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'open' then
      raise exception 'New quotations start open' using errcode = 'check_violation';
    end if;
    return new;
  end if;
  if old.status <> 'open' then
    raise exception 'Quotation % is % and cannot be changed', old.number, old.status using errcode = 'check_violation';
  end if;
  if new.customer_id <> old.customer_id or new.opportunity_id <> old.opportunity_id or new.currency <> old.currency then
    raise exception 'Customer, opportunity and currency cannot change after creation' using errcode = 'check_violation';
  end if;
  if new.status = 'won' and (new.awarded_revision_id is null or not exists (
       select 1 from public.quotation_revisions where id = new.awarded_revision_id
         and quotation_id = new.id and status = 'awarded')) then
    raise exception 'Use award_quotation() to mark a quotation won' using errcode = 'check_violation';
  end if;
  if new.status <> 'open' then
    new.closed_at := now();
  end if;
  return new;
end $$;
create trigger quotations_guard before insert or update on public.quotations
  for each row execute function public.quotations_guard();

-- ---------------------------------------------------------------------------
-- Workflow functions (called by the API inside the user's transaction)
-- ---------------------------------------------------------------------------

create or replace function public.create_quotation(
  p_opportunity_id uuid,
  p_title text,
  p_tender_id uuid default null,
  p_template_id uuid default null,
  p_currency char(3) default 'SAR'
) returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  v_opp public.opportunities%rowtype;
  v_q uuid;
  v_t public.quotation_templates%rowtype;
  v_s public.company_settings%rowtype;
begin
  if not public.has_permission('quotations.write') then
    raise exception 'Not permitted to create quotations' using errcode = 'insufficient_privilege';
  end if;
  select * into v_opp from public.opportunities where id = p_opportunity_id;
  if not found then
    raise exception 'Opportunity not found' using errcode = 'no_data_found';
  end if;
  if v_opp.customer_id is null then
    raise exception 'Link a customer to the opportunity before quoting' using errcode = 'check_violation';
  end if;
  if v_opp.stage in ('won', 'lost') then
    raise exception 'The opportunity is closed' using errcode = 'check_violation';
  end if;
  if p_tender_id is not null and not exists (select 1 from public.tenders where id = p_tender_id and opportunity_id = p_opportunity_id) then
    raise exception 'Tender does not belong to this opportunity' using errcode = 'check_violation';
  end if;
  select * into v_s from public.company_settings;

  insert into public.quotations (opportunity_id, tender_id, customer_id, title, currency)
  values (p_opportunity_id, p_tender_id, v_opp.customer_id, p_title, coalesce(p_currency, v_s.base_currency))
  returning id into v_q;

  if p_template_id is not null then
    select * into v_t from public.quotation_templates where id = p_template_id;
    if not found then
      raise exception 'Quotation template not found' using errcode = 'no_data_found';
    end if;
  end if;

  insert into public.quotation_revisions (
    quotation_id, revision_no, subject, valid_until, vat_rate,
    scope_en, scope_ar, exclusions_en, exclusions_ar, payment_terms_en, payment_terms_ar,
    completion_period_en, completion_period_ar,
    overhead_pct, contingency_pct, pricing_method, markup_pct, target_margin_pct)
  values (
    v_q, 0, p_title, (now() at time zone 'Asia/Riyadh')::date + v_s.quotation_validity_days, v_s.default_vat_rate,
    v_t.scope_en, v_t.scope_ar, v_t.exclusions_en, v_t.exclusions_ar, v_t.payment_terms_en, v_t.payment_terms_ar,
    v_t.completion_period_en, v_t.completion_period_ar,
    coalesce(v_t.overhead_pct, 10), coalesce(v_t.contingency_pct, 5), coalesce(v_t.pricing_method, 'markup'),
    coalesce(v_t.markup_pct, 15), coalesce(v_t.target_margin_pct, 15));

  perform public.advance_opportunity(p_opportunity_id, 'estimation');
  if p_tender_id is not null then
    update public.tenders set status = 'estimating' where id = p_tender_id and status in ('received', 'under_review');
  end if;
  return v_q;
end $$;

create or replace function public.create_quotation_revision(p_quotation_id uuid) returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  v_prev public.quotation_revisions%rowtype;
  v_new uuid;
begin
  if not public.has_permission('quotations.write') then
    raise exception 'Not permitted to revise quotations' using errcode = 'insufficient_privilege';
  end if;
  if (select status from public.quotations where id = p_quotation_id) is distinct from 'open' then
    raise exception 'Only open quotations can be revised' using errcode = 'check_violation';
  end if;
  select * into v_prev from public.quotation_revisions
   where quotation_id = p_quotation_id order by revision_no desc limit 1 for update;
  if v_prev.status in ('draft', 'pending_approval') then
    raise exception 'Revision % is still % ; finish it before starting a new one', v_prev.revision_no, v_prev.status
      using errcode = 'check_violation';
  end if;

  insert into public.quotation_revisions (
    quotation_id, revision_no, attention_contact_id, subject, valid_until,
    scope_en, scope_ar, exclusions_en, exclusions_ar, payment_terms_en, payment_terms_ar,
    completion_period_en, completion_period_ar, internal_notes, exchange_rate_to_base,
    overhead_pct, contingency_pct, pricing_method, markup_pct, target_margin_pct,
    discount_type, discount_value, vat_code, vat_rate)
  select quotation_id, v_prev.revision_no + 1, attention_contact_id, subject,
    greatest(valid_until, (now() at time zone 'Asia/Riyadh')::date + (select quotation_validity_days from public.company_settings)),
    scope_en, scope_ar, exclusions_en, exclusions_ar, payment_terms_en, payment_terms_ar,
    completion_period_en, completion_period_ar, internal_notes, exchange_rate_to_base,
    overhead_pct, contingency_pct, pricing_method, markup_pct, target_margin_pct,
    discount_type, discount_value, vat_code, vat_rate
  from public.quotation_revisions where id = v_prev.id
  returning id into v_new;

  insert into public.quotation_lines (revision_id, sort_order, section, item_code, description_en, description_ar,
    unit, quantity, material_unit_cost, labour_unit_cost, equipment_unit_cost, subcontract_unit_cost, other_unit_cost)
  select v_new, sort_order, section, item_code, description_en, description_ar,
    unit, quantity, material_unit_cost, labour_unit_cost, equipment_unit_cost, subcontract_unit_cost, other_unit_cost
  from public.quotation_lines where revision_id = v_prev.id;

  perform public.recalculate_revision(v_new);
  return v_new;
end $$;

create or replace function public.apply_boq_template(p_revision_id uuid, p_template_id uuid) returns integer
language plpgsql security invoker set search_path = public as $$
declare
  v_start integer;
  v_count integer;
begin
  select coalesce(max(sort_order), 0) into v_start from public.quotation_lines where revision_id = p_revision_id;
  insert into public.quotation_lines (revision_id, sort_order, section, item_code, description_en, description_ar,
    unit, quantity, material_unit_cost, labour_unit_cost, equipment_unit_cost, subcontract_unit_cost, other_unit_cost)
  select p_revision_id, v_start + row_number() over (order by sort_order, item_code) * 10, section, item_code,
    description_en, description_ar, unit, quantity, material_unit_cost, labour_unit_cost, equipment_unit_cost,
    subcontract_unit_cost, other_unit_cost
  from public.boq_template_items where template_id = p_template_id;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

create or replace function public.award_quotation(
  p_revision_id uuid,
  p_project_name text,
  p_project_manager_id uuid,
  p_start_date date,
  p_target_completion_date date,
  p_signed_date date default null,
  p_retention_pct numeric default 0,
  p_advance_payment_pct numeric default 0
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rev public.quotation_revisions%rowtype;
  v_q public.quotations%rowtype;
  v_contract uuid;
  v_project uuid;
  v_snapshot jsonb;
begin
  if not (public.has_permission('quotations.award') and public.has_permission('quotations.read')) then
    raise exception 'Not permitted to award quotations' using errcode = 'insufficient_privilege';
  end if;
  select * into v_rev from public.quotation_revisions where id = p_revision_id for update;
  if not found then
    raise exception 'Revision not found' using errcode = 'no_data_found';
  end if;
  select * into v_q from public.quotations where id = v_rev.quotation_id for update;
  if v_q.status <> 'open' then
    raise exception 'Quotation % is already %', v_q.number, v_q.status using errcode = 'check_violation';
  end if;
  if v_rev.status <> 'submitted' then
    raise exception 'Only the revision submitted to the client can be awarded (this one is %)', v_rev.status
      using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.app_users where id = p_project_manager_id and is_active) then
    raise exception 'Project manager must be an active user' using errcode = 'check_violation';
  end if;

  update public.quotation_revisions set status = 'awarded' where id = p_revision_id;
  update public.quotations set status = 'won', awarded_revision_id = p_revision_id where id = v_q.id;
  update public.opportunities set stage = 'won', win_probability = 100 where id = v_q.opportunity_id;
  if v_q.tender_id is not null then
    update public.tenders set status = 'won' where id = v_q.tender_id;
  end if;

  select to_jsonb(r) || jsonb_build_object(
           'quotation_number', v_q.number,
           'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.sort_order, l.created_at)
                              from public.quotation_lines l where l.revision_id = r.id), '[]'::jsonb))
    into v_snapshot
  from public.quotation_revisions r where r.id = p_revision_id;

  insert into public.contracts (customer_id, opportunity_id, quotation_id, quotation_revision_id, title, currency,
    exchange_rate_to_base, original_value, vat_rate, retention_pct, advance_payment_pct, signed_date, awarded_snapshot)
  values (v_q.customer_id, v_q.opportunity_id, v_q.id, p_revision_id, v_q.title, v_q.currency,
    v_rev.exchange_rate_to_base, v_rev.net_amount, v_rev.vat_rate, coalesce(p_retention_pct, 0),
    coalesce(p_advance_payment_pct, 0), p_signed_date, v_snapshot)
  returning id into v_contract;

  insert into public.projects (contract_id, customer_id, name, project_manager_id, start_date,
    target_completion_date, approved_budget)
  values (v_contract, v_q.customer_id, coalesce(nullif(trim(p_project_name), ''), v_q.title), p_project_manager_id,
    p_start_date, p_target_completion_date, v_rev.total_cost)
  returning id into v_project;

  perform public.log_event('quotations', v_q.id::text, 'Quotation awarded',
    jsonb_build_object('revision_id', p_revision_id, 'contract_id', v_contract, 'project_id', v_project));
  return jsonb_build_object('contract_id', v_contract, 'project_id', v_project);
end $$;
revoke all on function public.award_quotation(uuid, text, uuid, date, date, date, numeric, numeric) from public;

create or replace function public.mark_quotation_lost(p_quotation_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_q public.quotations%rowtype;
begin
  if not public.has_permission('quotations.award') then
    raise exception 'Not permitted to close quotations' using errcode = 'insufficient_privilege';
  end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'A reason is required' using errcode = 'check_violation';
  end if;
  select * into v_q from public.quotations where id = p_quotation_id for update;
  if not found then
    raise exception 'Quotation not found' using errcode = 'no_data_found';
  end if;
  update public.quotations set status = 'lost', lost_reason = p_reason where id = p_quotation_id;
  if v_q.tender_id is not null then
    update public.tenders set status = 'lost' where id = v_q.tender_id and status not in ('won', 'lost');
  end if;
  if not exists (select 1 from public.quotations where opportunity_id = v_q.opportunity_id and status in ('open', 'won')) then
    update public.opportunities set stage = 'lost', lost_reason = p_reason, win_probability = 0
     where id = v_q.opportunity_id and stage <> 'won';
  end if;
end $$;
revoke all on function public.mark_quotation_lost(uuid, text) from public;

-- updated_at and audit
create trigger boq_templates_updated before update on public.boq_templates for each row execute function public.set_updated_at();
create trigger quotation_templates_updated before update on public.quotation_templates for each row execute function public.set_updated_at();
create trigger quotations_updated before update on public.quotations for each row execute function public.set_updated_at();
create trigger quotation_revisions_updated before update on public.quotation_revisions for each row execute function public.set_updated_at();
create trigger quotation_lines_updated before update on public.quotation_lines for each row execute function public.set_updated_at();
create trigger contracts_updated before update on public.contracts for each row execute function public.set_updated_at();
create trigger projects_updated before update on public.projects for each row execute function public.set_updated_at();

create trigger audit_boq_templates after insert or update or delete on public.boq_templates for each row execute function public.audit_trigger();
create trigger audit_quotation_templates after insert or update or delete on public.quotation_templates for each row execute function public.audit_trigger();
create trigger audit_quotations after insert or update or delete on public.quotations for each row execute function public.audit_trigger();
create trigger audit_quotation_revisions after insert or update or delete on public.quotation_revisions for each row execute function public.audit_trigger();
create trigger audit_quotation_lines after insert or update or delete on public.quotation_lines for each row execute function public.audit_trigger();
create trigger audit_contracts after insert or update or delete on public.contracts for each row execute function public.audit_trigger();
create trigger audit_projects after insert or update or delete on public.projects for each row execute function public.audit_trigger();
