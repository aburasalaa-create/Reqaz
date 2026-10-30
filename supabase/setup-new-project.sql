-- RMS database setup for a NEW Supabase project (staging or production).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run. Run it once only.
-- Generated from supabase/migrations/*.sql — do not edit by hand. Contains no test data.

-- ===== 20261027000001_foundation.sql =====
-- RMS foundation: users, roles, permissions, settings, numbering, audit.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Users, roles and permissions
-- ---------------------------------------------------------------------------

create table public.app_users (
  id uuid primary key references auth.users (id) on delete restrict,
  email text not null unique,
  full_name text not null default '',
  full_name_ar text,
  phone text,
  locale text not null default 'en' check (locale in ('en', 'ar')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger app_users_updated before update on public.app_users
  for each row execute function public.set_updated_at();

create table public.permissions (
  code text primary key,
  module text not null,
  description text not null
);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[a-z_]+$'),
  name_en text not null,
  name_ar text not null,
  is_system boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.role_permissions (
  role_id uuid not null references public.roles (id) on delete cascade,
  permission_code text not null references public.permissions (code) on delete cascade,
  primary key (role_id, permission_code)
);

create table public.user_roles (
  user_id uuid not null references public.app_users (id) on delete cascade,
  role_id uuid not null references public.roles (id) on delete restrict,
  granted_at timestamptz not null default now(),
  granted_by uuid references public.app_users (id),
  primary key (user_id, role_id)
);
create index user_roles_role_idx on public.user_roles (role_id);

-- True when the current (JWT) user is active and holds the permission.
create or replace function public.has_permission(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.app_users u
    join public.user_roles ur on ur.user_id = u.id
    join public.role_permissions rp on rp.role_id = ur.role_id
    where u.id = auth.uid()
      and u.is_active
      and rp.permission_code = p_code
  )
$$;

create or replace function public.current_permissions() returns setof text
language sql stable security definer set search_path = public as $$
  select distinct rp.permission_code
  from public.app_users u
  join public.user_roles ur on ur.user_id = u.id
  join public.role_permissions rp on rp.role_id = ur.role_id
  where u.id = auth.uid() and u.is_active
$$;

create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_users where id = auth.uid() and is_active)
$$;

-- Create the profile row when Supabase Auth creates a user (invite or admin create).
create or replace function public.handle_new_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.app_users (id, email, full_name)
  values (new.id, coalesce(new.email, new.id::text),
          coalesce(new.raw_user_meta_data ->> 'full_name', ''))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ---------------------------------------------------------------------------
-- Company settings, currencies, VAT codes
-- ---------------------------------------------------------------------------

create table public.company_settings (
  id boolean primary key default true check (id),           -- single row
  legal_name_en text not null default 'Reqaz United Contracting',
  legal_name_ar text not null default 'شركة ركاز المتحدة للمقاولات',
  vat_number text,
  cr_number text,
  address_en text,
  address_ar text,
  phone text,
  email text,
  website text default 'https://www.reqaz.com',
  base_currency char(3) not null default 'SAR',
  default_vat_rate numeric(5, 2) not null default 15.00,
  quotation_validity_days integer not null default 30,
  allow_self_approval boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into public.company_settings default values;
create trigger company_settings_updated before update on public.company_settings
  for each row execute function public.set_updated_at();

create table public.currencies (
  code char(3) primary key check (code ~ '^[A-Z]{3}$'),
  name_en text not null,
  name_ar text not null,
  decimals smallint not null default 2,
  is_active boolean not null default true
);
insert into public.currencies (code, name_en, name_ar) values
  ('SAR', 'Saudi Riyal', 'ريال سعودي'),
  ('USD', 'US Dollar', 'دولار أمريكي'),
  ('EUR', 'Euro', 'يورو'),
  ('AED', 'UAE Dirham', 'درهم إماراتي');

create table public.exchange_rates (
  id uuid primary key default gen_random_uuid(),
  currency char(3) not null references public.currencies (code),
  rate_date date not null,
  rate_to_base numeric(18, 8) not null check (rate_to_base > 0),
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  unique (currency, rate_date)
);

create table public.vat_codes (
  code text primary key,
  name_en text not null,
  name_ar text not null,
  rate numeric(5, 2) not null check (rate >= 0 and rate < 100),
  zatca_category char(1) not null check (zatca_category in ('S', 'Z', 'E', 'O')),
  is_active boolean not null default true
);
insert into public.vat_codes (code, name_en, name_ar, rate, zatca_category) values
  ('S15', 'Standard rate 15%', 'النسبة الأساسية 15%', 15.00, 'S'),
  ('Z0', 'Zero rated', 'خاضع بنسبة صفر', 0, 'Z'),
  ('E', 'Exempt', 'معفى', 0, 'E'),
  ('O', 'Out of scope', 'خارج النطاق', 0, 'O');

-- ---------------------------------------------------------------------------
-- Sequential document numbers (gap-free: the counter row is locked and the
-- increment rolls back with the surrounding transaction).
-- ---------------------------------------------------------------------------

create table public.document_sequences (
  doc_type text not null,
  period integer not null,          -- year, or 0 for non-yearly sequences
  last_value integer not null default 0,
  primary key (doc_type, period)
);

create or replace function public.next_document_number(p_doc_type text, p_prefix text, p_yearly boolean default true, p_width integer default 4)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_period integer := case when p_yearly then extract(year from (now() at time zone 'Asia/Riyadh'))::integer else 0 end;
  v_value integer;
begin
  insert into public.document_sequences as s (doc_type, period, last_value)
  values (p_doc_type, v_period, 1)
  on conflict (doc_type, period) do update set last_value = s.last_value + 1
  returning last_value into v_value;

  if p_yearly then
    return p_prefix || '-' || v_period || '-' || lpad(v_value::text, p_width, '0');
  end if;
  return p_prefix || '-' || lpad(v_value::text, p_width, '0');
end $$;
revoke all on function public.next_document_number(text, text, boolean, integer) from public;

-- ---------------------------------------------------------------------------
-- Audit log (append-only)
-- ---------------------------------------------------------------------------

create table public.audit_events (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  actor_id uuid,
  table_name text not null,
  record_id text,
  action text not null check (action in ('INSERT', 'UPDATE', 'DELETE', 'EVENT')),
  old_data jsonb,
  new_data jsonb,
  note text
);
create index audit_events_record_idx on public.audit_events (table_name, record_id);
create index audit_events_time_idx on public.audit_events (occurred_at desc);

create or replace function public.audit_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_id text;
begin
  if tg_op in ('UPDATE', 'DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT', 'UPDATE') then v_new := to_jsonb(new); end if;
  if tg_op = 'UPDATE' and v_old = v_new then
    return new;
  end if;
  v_id := coalesce(v_new ->> 'id', v_old ->> 'id');
  insert into public.audit_events (actor_id, table_name, record_id, action, old_data, new_data)
  values (auth.uid(), tg_table_name, v_id, tg_op, v_old, v_new);
  return coalesce(new, old);
end $$;

create or replace function public.log_event(p_table text, p_record_id text, p_note text, p_data jsonb default null)
returns void
language sql security definer set search_path = public as $$
  insert into public.audit_events (actor_id, table_name, record_id, action, new_data, note)
  values (auth.uid(), p_table, p_record_id, 'EVENT', p_data, p_note);
$$;
revoke all on function public.log_event(text, text, text, jsonb) from public;

-- Prevent tampering with the audit log, even by table owners acting through the API.
create or replace function public.audit_events_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'audit_events is append-only' using errcode = 'insufficient_privilege';
end $$;
create trigger audit_events_no_update before update or delete on public.audit_events
  for each row execute function public.audit_events_immutable();

create trigger audit_app_users after insert or update or delete on public.app_users
  for each row execute function public.audit_trigger();
create trigger audit_user_roles after insert or update or delete on public.user_roles
  for each row execute function public.audit_trigger();
create trigger audit_role_permissions after insert or update or delete on public.role_permissions
  for each row execute function public.audit_trigger();
create trigger audit_company_settings after update on public.company_settings
  for each row execute function public.audit_trigger();

-- ---------------------------------------------------------------------------
-- Permission catalogue and default roles
-- ---------------------------------------------------------------------------

insert into public.permissions (code, module, description) values
  ('dashboard.read', 'dashboard', 'View the executive dashboard'),
  ('customers.read', 'customers', 'View customers and contacts'),
  ('customers.write', 'customers', 'Create and edit customers and contacts'),
  ('suppliers.read', 'suppliers', 'View suppliers'),
  ('suppliers.write', 'suppliers', 'Create and edit suppliers'),
  ('crm.read', 'crm', 'View leads, opportunities and follow-ups'),
  ('crm.write', 'crm', 'Create and edit leads, opportunities and follow-ups'),
  ('tenders.read', 'tenders', 'View tenders and RFQs'),
  ('tenders.write', 'tenders', 'Create and edit tenders and RFQs'),
  ('estimation.read', 'estimation', 'View BOQ and quotation templates'),
  ('estimation.write', 'estimation', 'Manage BOQ and quotation templates'),
  ('quotations.read', 'quotations', 'View quotations and pricing'),
  ('quotations.write', 'quotations', 'Prepare and revise quotations'),
  ('quotations.approve', 'quotations', 'Approve or reject quotations'),
  ('quotations.submit', 'quotations', 'Record a quotation as submitted to the client'),
  ('quotations.award', 'quotations', 'Mark quotations won or lost and create contracts'),
  ('contracts.read', 'contracts', 'View contracts'),
  ('projects.read', 'projects', 'View projects'),
  ('settings.manage', 'admin', 'Manage company settings, currencies and rates'),
  ('users.manage', 'admin', 'Manage users and role assignments'),
  ('audit.read', 'admin', 'View the audit log');

insert into public.roles (code, name_en, name_ar, is_system) values
  ('administrator', 'Administrator', 'مدير النظام', true),
  ('general_manager', 'General Manager', 'المدير العام', true),
  ('sales', 'Sales', 'المبيعات', true),
  ('estimation', 'Estimation', 'التسعير والتقدير', true),
  ('project_management', 'Project Management', 'إدارة المشاريع', true),
  ('site_engineering', 'Site Engineering', 'هندسة الموقع', true),
  ('finance', 'Finance', 'المالية', true),
  ('document_control', 'Document Control', 'ضبط الوثائق', true),
  ('procurement', 'Procurement', 'المشتريات', true);

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
from public.roles r
join public.permissions p on (
  r.code = 'administrator'
  or (r.code = 'general_manager' and p.code not in ('settings.manage', 'users.manage'))
  or (r.code = 'sales' and p.code in ('dashboard.read', 'customers.read', 'customers.write', 'crm.read', 'crm.write',
      'tenders.read', 'tenders.write', 'estimation.read', 'quotations.read', 'quotations.write', 'quotations.submit'))
  or (r.code = 'estimation' and p.code in ('dashboard.read', 'customers.read', 'suppliers.read', 'crm.read', 'tenders.read',
      'tenders.write', 'estimation.read', 'estimation.write', 'quotations.read', 'quotations.write'))
  or (r.code = 'project_management' and p.code in ('dashboard.read', 'customers.read', 'crm.read', 'tenders.read',
      'quotations.read', 'contracts.read', 'projects.read'))
  or (r.code = 'site_engineering' and p.code in ('projects.read'))
  or (r.code = 'finance' and p.code in ('dashboard.read', 'customers.read', 'suppliers.read', 'suppliers.write',
      'quotations.read', 'contracts.read', 'projects.read'))
  or (r.code = 'document_control' and p.code in ('customers.read', 'tenders.read', 'contracts.read', 'projects.read'))
  or (r.code = 'procurement' and p.code in ('suppliers.read', 'suppliers.write', 'projects.read'))
);

-- Bootstrap: the very first user becomes the administrator. Public sign-up is disabled
-- in Supabase Auth, so later users only exist when an administrator invites them.
create or replace function public.bootstrap_first_admin() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.app_users) = 1 then
    insert into public.user_roles (user_id, role_id)
    select new.id, id from public.roles where code = 'administrator';
  end if;
  return null;
end $$;
create trigger app_users_bootstrap_admin after insert on public.app_users
  for each row execute function public.bootstrap_first_admin();

-- ===== 20261027000002_crm.sql =====
-- RMS Phase 1: customers, contacts, suppliers, leads, opportunities, follow-ups, tenders, attachments.

create type public.party_type as enum ('company', 'government', 'individual');
create type public.lead_source as enum ('website', 'manual', 'email', 'referral', 'phone', 'other');
create type public.opportunity_stage as enum (
  'new_lead', 'qualified', 'tender_received', 'estimation', 'internal_review',
  'quotation_submitted', 'negotiation', 'won', 'lost'
);
create type public.tender_status as enum (
  'received', 'under_review', 'estimating', 'submitted', 'won', 'lost', 'no_bid', 'cancelled'
);
create type public.follow_up_type as enum ('call', 'meeting', 'email', 'site_visit', 'task');

-- Saudi VAT registration numbers are 15 digits, starting and ending with 3.
create or replace function public.is_valid_sa_vat_number(p text) returns boolean
language sql immutable as $$ select p ~ '^3[0-9]{13}3$' $$;

-- ---------------------------------------------------------------------------
-- Customers and contacts
-- ---------------------------------------------------------------------------

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  party_type public.party_type not null default 'company',
  name_en text not null check (length(trim(name_en)) > 0),
  name_ar text,
  cr_number text,
  vat_number text check (vat_number is null or public.is_valid_sa_vat_number(vat_number)),
  email text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone text,
  website text,
  building_number text,
  street text,
  district text,
  city text,
  postal_code text,
  country char(2) not null default 'SA',
  payment_terms_days integer not null default 30 check (payment_terms_days between 0 and 365),
  currency char(3) not null default 'SAR' references public.currencies (code),
  credit_limit numeric(18, 2) check (credit_limit is null or credit_limit >= 0),
  notes text,
  is_active boolean not null default true,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index customers_name_trgm on public.customers using gin (name_en extensions.gin_trgm_ops);
create index customers_name_ar_trgm on public.customers using gin (name_ar extensions.gin_trgm_ops);
create unique index customers_vat_unique on public.customers (vat_number) where vat_number is not null;

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers (id) on delete cascade,
  full_name text not null check (length(trim(full_name)) > 0),
  position text,
  email text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone text,
  is_primary boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index contacts_customer_idx on public.contacts (customer_id);
create unique index contacts_one_primary on public.contacts (customer_id) where is_primary;

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_en text not null check (length(trim(name_en)) > 0),
  name_ar text,
  category text,
  cr_number text,
  vat_number text check (vat_number is null or public.is_valid_sa_vat_number(vat_number)),
  email text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone text,
  city text,
  country char(2) not null default 'SA',
  payment_terms_days integer not null default 30 check (payment_terms_days between 0 and 365),
  currency char(3) not null default 'SAR' references public.currencies (code),
  contact_name text,
  notes text,
  is_active boolean not null default true,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index suppliers_name_trgm on public.suppliers using gin (name_en extensions.gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- Opportunities (pipeline cards) and inbound leads
-- ---------------------------------------------------------------------------

create table public.opportunities (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  title text not null check (length(trim(title)) > 0),
  customer_id uuid references public.customers (id) on delete restrict,
  -- Prospect details captured before a customer record exists.
  prospect_company text,
  prospect_contact text,
  prospect_email text,
  prospect_phone text,
  source public.lead_source not null default 'manual',
  stage public.opportunity_stage not null default 'new_lead',
  stage_changed_at timestamptz not null default now(),
  owner_id uuid references public.app_users (id) default auth.uid(),
  service_type text,
  location text,
  description text,
  expected_value numeric(18, 2) check (expected_value is null or expected_value >= 0),
  currency char(3) not null default 'SAR' references public.currencies (code),
  win_probability integer not null default 10 check (win_probability between 0 and 100),
  expected_close_date date,
  lost_reason text,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint opportunities_lost_reason check (stage <> 'lost' or length(trim(coalesce(lost_reason, ''))) > 0),
  constraint opportunities_customer_after_qualified check (
    stage in ('new_lead', 'qualified', 'lost') or customer_id is not null
  )
);
create index opportunities_stage_idx on public.opportunities (stage);
create index opportunities_customer_idx on public.opportunities (customer_id);
create index opportunities_owner_idx on public.opportunities (owner_id);

create table public.opportunity_stage_history (
  id bigint generated always as identity primary key,
  opportunity_id uuid not null references public.opportunities (id) on delete cascade,
  from_stage public.opportunity_stage,
  to_stage public.opportunity_stage not null,
  changed_by uuid default auth.uid(),
  changed_at timestamptz not null default now(),
  note text
);
create index opportunity_stage_history_opp_idx on public.opportunity_stage_history (opportunity_id);

create table public.leads (
  id uuid primary key default gen_random_uuid(),
  source public.lead_source not null,
  -- Idempotency key supplied by the sending system (e.g. WordPress submission id).
  external_id text,
  contact_name text,
  company_name text,
  email text,
  phone text,
  service_interest text,
  message text,
  received_at timestamptz not null default now(),
  status text not null default 'new' check (status in ('new', 'converted', 'rejected', 'spam')),
  opportunity_id uuid references public.opportunities (id) on delete set null,
  raw_payload jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source, external_id)
);
create index leads_status_idx on public.leads (status);

create table public.follow_ups (
  id uuid primary key default gen_random_uuid(),
  opportunity_id uuid not null references public.opportunities (id) on delete cascade,
  type public.follow_up_type not null default 'call',
  subject text not null check (length(trim(subject)) > 0),
  due_at timestamptz not null,
  assigned_to uuid references public.app_users (id) default auth.uid(),
  completed_at timestamptz,
  outcome text,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index follow_ups_open_idx on public.follow_ups (due_at) where completed_at is null;
create index follow_ups_opp_idx on public.follow_ups (opportunity_id);

-- ---------------------------------------------------------------------------
-- Tenders / RFQs
-- ---------------------------------------------------------------------------

create table public.tenders (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  opportunity_id uuid not null references public.opportunities (id) on delete restrict,
  customer_id uuid not null references public.customers (id) on delete restrict,
  client_reference text,
  title text not null check (length(trim(title)) > 0),
  issue_date date,
  clarification_deadline timestamptz,
  site_visit_at timestamptz,
  submission_deadline timestamptz not null,
  bid_bond_required boolean not null default false,
  bid_bond_amount numeric(18, 2) check (bid_bond_amount is null or bid_bond_amount >= 0),
  status public.tender_status not null default 'received',
  notes text,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index tenders_deadline_idx on public.tenders (submission_deadline);
create index tenders_opp_idx on public.tenders (opportunity_id);

-- ---------------------------------------------------------------------------
-- Attachments (file bytes live in private object storage; this is the register)
-- ---------------------------------------------------------------------------

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type in ('customer', 'opportunity', 'tender', 'quotation', 'quotation_revision', 'contract', 'project')),
  entity_id uuid not null,
  file_name text not null,
  mime_type text not null,
  size_bytes bigint not null check (size_bytes >= 0),
  sha256 text not null,
  storage_path text not null unique,
  category text,
  is_system_generated boolean not null default false,
  uploaded_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by uuid references public.app_users (id)
);
create index attachments_entity_idx on public.attachments (entity_type, entity_id);

-- ---------------------------------------------------------------------------
-- Numbering and lifecycle triggers
-- ---------------------------------------------------------------------------

create or replace function public.assign_number() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'customers' then
    new.code := public.next_document_number('customer', 'CUS', false, 5);
  elsif tg_table_name = 'suppliers' then
    new.code := public.next_document_number('supplier', 'SUP', false, 5);
  elsif tg_table_name = 'opportunities' then
    new.number := public.next_document_number('opportunity', 'OPP');
  elsif tg_table_name = 'tenders' then
    new.number := public.next_document_number('tender', 'TND');
  elsif tg_table_name = 'quotations' then
    new.number := public.next_document_number('quotation', 'QTN');
  elsif tg_table_name = 'contracts' then
    new.number := public.next_document_number('contract', 'CON', true, 3);
  elsif tg_table_name = 'projects' then
    new.number := public.next_document_number('project', 'PRJ', true, 3);
  end if;
  return new;
end $$;

create trigger customers_number before insert on public.customers
  for each row execute function public.assign_number();
create trigger suppliers_number before insert on public.suppliers
  for each row execute function public.assign_number();
create trigger opportunities_number before insert on public.opportunities
  for each row execute function public.assign_number();
create trigger tenders_number before insert on public.tenders
  for each row execute function public.assign_number();

-- Numbers are permanent once assigned.
create or replace function public.protect_number() returns trigger
language plpgsql as $$
begin
  if to_jsonb(new) ->> tg_argv[0] is distinct from to_jsonb(old) ->> tg_argv[0] then
    raise exception '% cannot be changed once assigned', tg_argv[0] using errcode = 'check_violation';
  end if;
  return new;
end $$;

create trigger customers_code_fixed before update on public.customers
  for each row execute function public.protect_number('code');
create trigger suppliers_code_fixed before update on public.suppliers
  for each row execute function public.protect_number('code');
create trigger opportunities_number_fixed before update on public.opportunities
  for each row execute function public.protect_number('number');
create trigger tenders_number_fixed before update on public.tenders
  for each row execute function public.protect_number('number');

-- Stage changes: record history, enforce that "won" only comes from awarding a quotation.
create or replace function public.opportunity_stage_change() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    insert into public.opportunity_stage_history (opportunity_id, from_stage, to_stage)
    values (new.id, null, new.stage);
    return new;
  end if;

  if new.stage is distinct from old.stage then
    if old.stage in ('won') then
      raise exception 'A won opportunity cannot change stage' using errcode = 'check_violation';
    end if;
    if new.stage = 'won' and not exists (
      select 1 from public.quotations q where q.opportunity_id = new.id and q.status = 'won'
    ) then
      raise exception 'An opportunity is marked won only by awarding a quotation' using errcode = 'check_violation';
    end if;
    if new.stage <> 'lost' then
      new.lost_reason := null;
    end if;
    new.stage_changed_at := now();
    insert into public.opportunity_stage_history (opportunity_id, from_stage, to_stage)
    values (new.id, old.stage, new.stage);
  end if;
  return new;
end $$;

create trigger opportunities_stage_insert after insert on public.opportunities
  for each row execute function public.opportunity_stage_change();
create trigger opportunities_stage_update before update on public.opportunities
  for each row execute function public.opportunity_stage_change();

-- History is written AFTER insert so it can reference the new row; 'won' is blocked BEFORE insert.
create or replace function public.opportunity_no_won_insert() returns trigger
language plpgsql as $$
begin
  if new.stage = 'won' then
    raise exception 'An opportunity is marked won only by awarding a quotation' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger opportunities_no_won_insert before insert on public.opportunities
  for each row execute function public.opportunity_no_won_insert();

-- Tender customer must match its opportunity customer.
create or replace function public.tender_consistency() returns trigger
language plpgsql as $$
declare
  v_customer uuid;
begin
  select customer_id into v_customer from public.opportunities where id = new.opportunity_id;
  if v_customer is null then
    raise exception 'Link a customer to the opportunity before recording a tender' using errcode = 'check_violation';
  end if;
  if new.customer_id is null then
    new.customer_id := v_customer;
  elsif new.customer_id <> v_customer then
    raise exception 'Tender customer must match the opportunity customer' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger tenders_consistency before insert or update of opportunity_id, customer_id on public.tenders
  for each row execute function public.tender_consistency();

-- Attachments are a register: only soft deletion is allowed.
create or replace function public.attachments_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Attachments cannot be deleted; mark them deleted instead' using errcode = 'insufficient_privilege';
  end if;
  if (to_jsonb(new) - 'deleted_at' - 'deleted_by') <> (to_jsonb(old) - 'deleted_at' - 'deleted_by') then
    raise exception 'Attachment metadata is immutable' using errcode = 'insufficient_privilege';
  end if;
  if old.deleted_at is not null then
    raise exception 'Attachment already deleted' using errcode = 'check_violation';
  end if;
  if old.is_system_generated then
    raise exception 'System-generated documents cannot be deleted' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger attachments_guard before update or delete on public.attachments
  for each row execute function public.attachments_guard();

-- updated_at and audit
create trigger customers_updated before update on public.customers for each row execute function public.set_updated_at();
create trigger contacts_updated before update on public.contacts for each row execute function public.set_updated_at();
create trigger suppliers_updated before update on public.suppliers for each row execute function public.set_updated_at();
create trigger opportunities_updated before update on public.opportunities for each row execute function public.set_updated_at();
create trigger leads_updated before update on public.leads for each row execute function public.set_updated_at();
create trigger follow_ups_updated before update on public.follow_ups for each row execute function public.set_updated_at();
create trigger tenders_updated before update on public.tenders for each row execute function public.set_updated_at();

create trigger audit_customers after insert or update or delete on public.customers for each row execute function public.audit_trigger();
create trigger audit_contacts after insert or update or delete on public.contacts for each row execute function public.audit_trigger();
create trigger audit_suppliers after insert or update or delete on public.suppliers for each row execute function public.audit_trigger();
create trigger audit_opportunities after insert or update or delete on public.opportunities for each row execute function public.audit_trigger();
create trigger audit_leads after insert or update or delete on public.leads for each row execute function public.audit_trigger();
create trigger audit_follow_ups after insert or update or delete on public.follow_ups for each row execute function public.audit_trigger();
create trigger audit_tenders after insert or update or delete on public.tenders for each row execute function public.audit_trigger();
create trigger audit_attachments after insert or update on public.attachments for each row execute function public.audit_trigger();

-- ===== 20261027000003_quotations.sql =====
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

-- ===== 20261027000004_security.sql =====
-- RMS Phase 1: grants and row-level security.
-- Every table has RLS enabled. Access is granted by permission (public.has_permission),
-- never by hiding UI. The anonymous role gets nothing.

-- Triggers that write to protected tables run as the table owner.
alter function public.opportunity_stage_change() security definer set search_path = public;
alter function public.quotation_lines_recalc() security definer set search_path = public;
alter function public.quotation_revision_params_recalc() security definer set search_path = public;

-- advance_opportunity is reachable from invoker functions; keep it to quotation users.
create or replace function public.advance_opportunity(p_opportunity_id uuid, p_stage public.opportunity_stage)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_permission('quotations.read') then
    return;
  end if;
  update public.opportunities
     set stage = p_stage
   where id = p_opportunity_id
     and stage < p_stage
     and stage not in ('won', 'lost');
end $$;

-- ---------------------------------------------------------------------------
-- User self-service limits and last-administrator protection
-- ---------------------------------------------------------------------------

create or replace function public.app_users_guard() returns trigger
language plpgsql as $$
begin
  if not public.has_permission('users.manage')
     and (new.is_active is distinct from old.is_active or new.email is distinct from old.email or new.id <> old.id) then
    raise exception 'Only user administrators can change status or email' using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger app_users_guard before update on public.app_users
  for each row execute function public.app_users_guard();

create or replace function public.ensure_an_administrator() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from public.user_roles ur
    join public.roles r on r.id = ur.role_id and r.code = 'administrator'
    join public.app_users u on u.id = ur.user_id and u.is_active
  ) and exists (select 1 from public.app_users) then
    raise exception 'At least one active administrator must remain' using errcode = 'check_violation';
  end if;
  return null;
end $$;
create constraint trigger user_roles_keep_admin after delete or update on public.user_roles
  deferrable initially deferred for each row execute function public.ensure_an_administrator();
create constraint trigger app_users_keep_admin after update of is_active on public.app_users
  deferrable initially deferred for each row execute function public.ensure_an_administrator();

-- ---------------------------------------------------------------------------
-- Attachment access follows the parent record's module permission
-- ---------------------------------------------------------------------------

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
    else false end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

revoke all on all tables in schema public from anon, public;
revoke all on all sequences in schema public from anon, public;
revoke execute on all functions in schema public from anon, public;

grant usage on schema public to authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;
grant execute on all functions in schema public to authenticated, service_role;

-- Internal helpers are not callable directly.
revoke execute on function public.next_document_number(text, text, boolean, integer) from authenticated;
revoke execute on function public.log_event(text, text, text, jsonb) from authenticated;
-- No direct access to the numbering counters.
revoke all on public.document_sequences from authenticated;
-- Append-only logs written by triggers: read-only for users.
revoke insert, update, delete, truncate on public.audit_events, public.quotation_approvals, public.opportunity_stage_history
  from authenticated;
-- Contracts and projects are created only by award_quotation() in Phase 1.
revoke insert, delete, truncate on public.contracts, public.projects from authenticated;
-- Reference catalogue maintained by migrations.
revoke insert, update, delete, truncate on public.permissions from authenticated;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array[
    'app_users', 'permissions', 'roles', 'role_permissions', 'user_roles', 'company_settings', 'currencies',
    'exchange_rates', 'vat_codes', 'document_sequences', 'audit_events', 'customers', 'contacts', 'suppliers',
    'opportunities', 'opportunity_stage_history', 'leads', 'follow_ups', 'tenders', 'attachments',
    'boq_templates', 'boq_template_items', 'quotation_templates', 'quotations', 'quotation_revisions',
    'quotation_lines', 'quotation_approvals', 'contracts', 'projects']
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Users and access control
create policy app_users_select on public.app_users for select to authenticated using (public.is_active_user());
create policy app_users_update on public.app_users for update to authenticated
  using (public.has_permission('users.manage') or id = auth.uid())
  with check (public.has_permission('users.manage') or id = auth.uid());

create policy permissions_select on public.permissions for select to authenticated using (public.is_active_user());

create policy roles_select on public.roles for select to authenticated using (public.is_active_user());
create policy roles_write on public.roles for all to authenticated
  using (public.has_permission('users.manage')) with check (public.has_permission('users.manage'));

create policy role_permissions_select on public.role_permissions for select to authenticated using (public.is_active_user());
create policy role_permissions_write on public.role_permissions for all to authenticated
  using (public.has_permission('users.manage')) with check (public.has_permission('users.manage'));

create policy user_roles_select on public.user_roles for select to authenticated
  using (public.has_permission('users.manage') or user_id = auth.uid());
create policy user_roles_write on public.user_roles for all to authenticated
  using (public.has_permission('users.manage')) with check (public.has_permission('users.manage'));

-- Settings and reference data
create policy company_settings_select on public.company_settings for select to authenticated using (public.is_active_user());
create policy company_settings_update on public.company_settings for update to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));

create policy currencies_select on public.currencies for select to authenticated using (public.is_active_user());
create policy currencies_write on public.currencies for all to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));

create policy vat_codes_select on public.vat_codes for select to authenticated using (public.is_active_user());
create policy vat_codes_write on public.vat_codes for all to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));

create policy exchange_rates_select on public.exchange_rates for select to authenticated using (public.is_active_user());
create policy exchange_rates_insert on public.exchange_rates for insert to authenticated
  with check (public.has_permission('settings.manage'));
create policy exchange_rates_update on public.exchange_rates for update to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));

create policy audit_events_select on public.audit_events for select to authenticated using (public.has_permission('audit.read'));

-- Customers, contacts, suppliers (no hard deletes of customers/suppliers: deactivate instead)
create policy customers_select on public.customers for select to authenticated using (public.has_permission('customers.read'));
create policy customers_insert on public.customers for insert to authenticated with check (public.has_permission('customers.write'));
create policy customers_update on public.customers for update to authenticated
  using (public.has_permission('customers.write')) with check (public.has_permission('customers.write'));

create policy contacts_select on public.contacts for select to authenticated using (public.has_permission('customers.read'));
create policy contacts_insert on public.contacts for insert to authenticated with check (public.has_permission('customers.write'));
create policy contacts_update on public.contacts for update to authenticated
  using (public.has_permission('customers.write')) with check (public.has_permission('customers.write'));
create policy contacts_delete on public.contacts for delete to authenticated using (public.has_permission('customers.write'));

create policy suppliers_select on public.suppliers for select to authenticated using (public.has_permission('suppliers.read'));
create policy suppliers_insert on public.suppliers for insert to authenticated with check (public.has_permission('suppliers.write'));
create policy suppliers_update on public.suppliers for update to authenticated
  using (public.has_permission('suppliers.write')) with check (public.has_permission('suppliers.write'));

-- CRM
create policy opportunities_select on public.opportunities for select to authenticated using (public.has_permission('crm.read'));
create policy opportunities_insert on public.opportunities for insert to authenticated with check (public.has_permission('crm.write'));
create policy opportunities_update on public.opportunities for update to authenticated
  using (public.has_permission('crm.write')) with check (public.has_permission('crm.write'));

create policy opportunity_stage_history_select on public.opportunity_stage_history for select to authenticated
  using (public.has_permission('crm.read'));

create policy leads_select on public.leads for select to authenticated using (public.has_permission('crm.read'));
create policy leads_insert on public.leads for insert to authenticated with check (public.has_permission('crm.write'));
create policy leads_update on public.leads for update to authenticated
  using (public.has_permission('crm.write')) with check (public.has_permission('crm.write'));

create policy follow_ups_select on public.follow_ups for select to authenticated using (public.has_permission('crm.read'));
create policy follow_ups_insert on public.follow_ups for insert to authenticated with check (public.has_permission('crm.write'));
create policy follow_ups_update on public.follow_ups for update to authenticated
  using (public.has_permission('crm.write')) with check (public.has_permission('crm.write'));
create policy follow_ups_delete on public.follow_ups for delete to authenticated using (public.has_permission('crm.write'));

create policy tenders_select on public.tenders for select to authenticated using (public.has_permission('tenders.read'));
create policy tenders_insert on public.tenders for insert to authenticated with check (public.has_permission('tenders.write'));
create policy tenders_update on public.tenders for update to authenticated
  using (public.has_permission('tenders.write')) with check (public.has_permission('tenders.write'));

create policy attachments_select on public.attachments for select to authenticated
  using (public.can_access_entity(entity_type, false));
create policy attachments_insert on public.attachments for insert to authenticated
  with check (public.can_access_entity(entity_type, true) and uploaded_by = auth.uid());
create policy attachments_update on public.attachments for update to authenticated
  using (public.can_access_entity(entity_type, true)) with check (public.can_access_entity(entity_type, true));

-- Estimation templates
create policy boq_templates_select on public.boq_templates for select to authenticated using (public.has_permission('estimation.read'));
create policy boq_templates_write on public.boq_templates for all to authenticated
  using (public.has_permission('estimation.write')) with check (public.has_permission('estimation.write'));
create policy boq_template_items_select on public.boq_template_items for select to authenticated using (public.has_permission('estimation.read'));
create policy boq_template_items_write on public.boq_template_items for all to authenticated
  using (public.has_permission('estimation.write')) with check (public.has_permission('estimation.write'));
create policy quotation_templates_select on public.quotation_templates for select to authenticated using (public.has_permission('estimation.read'));
create policy quotation_templates_write on public.quotation_templates for all to authenticated
  using (public.has_permission('estimation.write')) with check (public.has_permission('estimation.write'));

-- Quotations
create policy quotations_select on public.quotations for select to authenticated using (public.has_permission('quotations.read'));
create policy quotations_insert on public.quotations for insert to authenticated with check (public.has_permission('quotations.write'));
create policy quotations_update on public.quotations for update to authenticated
  using (public.has_permission('quotations.write')) with check (public.has_permission('quotations.write'));

create policy quotation_revisions_select on public.quotation_revisions for select to authenticated
  using (public.has_permission('quotations.read'));
create policy quotation_revisions_insert on public.quotation_revisions for insert to authenticated
  with check (public.has_permission('quotations.write'));
create policy quotation_revisions_update on public.quotation_revisions for update to authenticated
  using (public.has_permission('quotations.write') or public.has_permission('quotations.approve')
         or public.has_permission('quotations.submit') or public.has_permission('quotations.award'))
  with check (public.has_permission('quotations.write') or public.has_permission('quotations.approve')
         or public.has_permission('quotations.submit') or public.has_permission('quotations.award'));

create policy quotation_lines_select on public.quotation_lines for select to authenticated using (public.has_permission('quotations.read'));
create policy quotation_lines_insert on public.quotation_lines for insert to authenticated with check (public.has_permission('quotations.write'));
create policy quotation_lines_update on public.quotation_lines for update to authenticated
  using (public.has_permission('quotations.write')) with check (public.has_permission('quotations.write'));
create policy quotation_lines_delete on public.quotation_lines for delete to authenticated using (public.has_permission('quotations.write'));

create policy quotation_approvals_select on public.quotation_approvals for select to authenticated
  using (public.has_permission('quotations.read'));

-- Contracts and projects are created by award_quotation(); edited in Phase 2.
create policy contracts_select on public.contracts for select to authenticated
  using (public.has_permission('contracts.read') or public.has_permission('quotations.award'));
create policy projects_select on public.projects for select to authenticated
  using (public.has_permission('projects.read') or public.has_permission('quotations.award'));

-- ===== 20261027000005_proposal_format.sql =====
-- Proposal format modelled on Reqaz's own proposals: cover page, cover letter, summary & terms
-- (schedule, payment milestones, warranty), compliance matrix and a lump-sum financial proposal.

alter table public.company_settings
  alter column legal_name_en set default 'REQAZ UNITED CONTRACTING CO. LTD.';
update public.company_settings set
  legal_name_en = 'REQAZ UNITED CONTRACTING CO. LTD.',
  cr_number = coalesce(cr_number, '4030399230'),
  address_en = coalesce(address_en, '3035 AZIZYA 8552, Jeddah 23334, KSA'),
  phone = coalesce(phone, '920009802'),
  email = coalesce(email, 'info@reqaz.com'),
  website = coalesce(website, 'www.reqaz.com')
where legal_name_en = 'Reqaz United Contracting';

alter table public.app_users add column if not exists job_title text;

-- Quotation reference shown to the client, e.g. 'ARS/RUH111026-01' → printed as 'ARS/RUH111026-01R00'.
alter table public.quotations add column reference_prefix text check (reference_prefix is null or length(reference_prefix) <= 60);

create type public.price_display as enum ('itemised', 'lump_sum_sections');

alter table public.quotation_revisions
  add column project_name text,
  add column project_location text,
  add column client_rfp_reference text,
  add column cc text,
  add column signatory_id uuid references public.app_users (id),
  add column cover_letter_en text,
  add column cover_letter_ar text,
  add column executive_summary_en text,
  add column executive_summary_ar text,
  add column general_terms_en text,
  add column general_terms_ar text,
  add column warranty_en text,
  add column warranty_ar text,
  add column price_display public.price_display not null default 'itemised',
  -- [{"label": "Mile stone 1", "description": "...", "duration": "12 days"}]
  add column schedule jsonb not null default '[]'::jsonb check (jsonb_typeof(schedule) = 'array'),
  -- [{"description": "Advance payment on signing", "percent": 15}]
  add column payment_milestones jsonb not null default '[]'::jsonb check (jsonb_typeof(payment_milestones) = 'array'),
  -- [{"ref": "3.2", "requirement": "...", "status": "Comply"}]
  add column compliance jsonb not null default '[]'::jsonb check (jsonb_typeof(compliance) = 'array');

-- Payment milestones must total exactly 100% before a quotation goes for approval.
create or replace function public.payment_milestones_total(p jsonb) returns numeric
language sql immutable as $$
  select coalesce(sum((e ->> 'percent')::numeric), 0) from jsonb_array_elements(p) e
$$;

create or replace function public.quotation_revision_proposal_checks() returns trigger
language plpgsql as $$
begin
  if new.status = 'pending_approval' and old.status = 'draft'
     and jsonb_array_length(new.payment_milestones) > 0
     and public.payment_milestones_total(new.payment_milestones) <> 100 then
    raise exception 'Payment milestones total % percent; they must total 100 percent',
      public.payment_milestones_total(new.payment_milestones) using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger quotation_revisions_proposal_checks before update of status on public.quotation_revisions
  for each row execute function public.quotation_revision_proposal_checks();

-- New revisions carry the proposal content forward.
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
    discount_type, discount_value, vat_code, vat_rate,
    project_name, project_location, client_rfp_reference, cc, signatory_id, cover_letter_en, cover_letter_ar,
    executive_summary_en, executive_summary_ar, general_terms_en, general_terms_ar, warranty_en, warranty_ar,
    price_display, schedule, payment_milestones, compliance)
  select quotation_id, v_prev.revision_no + 1, attention_contact_id, subject,
    greatest(valid_until, (now() at time zone 'Asia/Riyadh')::date + (select quotation_validity_days from public.company_settings)),
    scope_en, scope_ar, exclusions_en, exclusions_ar, payment_terms_en, payment_terms_ar,
    completion_period_en, completion_period_ar, internal_notes, exchange_rate_to_base,
    overhead_pct, contingency_pct, pricing_method, markup_pct, target_margin_pct,
    discount_type, discount_value, vat_code, vat_rate,
    project_name, project_location, client_rfp_reference, cc, signatory_id, cover_letter_en, cover_letter_ar,
    executive_summary_en, executive_summary_ar, general_terms_en, general_terms_ar, warranty_en, warranty_ar,
    price_display, schedule, payment_milestones, compliance
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

grant execute on function public.payment_milestones_total(jsonb) to authenticated;
revoke execute on function public.payment_milestones_total(jsonb) from anon, public;

-- ===== 20261029000006_invoicing.sql =====
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

-- ===== 20261030000007_bank_accounts.sql =====
-- Company bank accounts: Reqaz banks with more than one bank, and invoices print all accounts marked for invoices.
alter table public.company_settings add column bank_accounts jsonb not null default '[]'::jsonb
  check (jsonb_typeof(bank_accounts) = 'array');

update public.company_settings
   set bank_accounts = jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
         'bank_name', bank_name, 'account_name', bank_account_name, 'iban', bank_iban, 'show_on_invoices', true)))
 where bank_iban is not null;

alter table public.company_settings drop column bank_name, drop column bank_iban, drop column bank_account_name;

-- ===== 20261030000008_brand_assets.sql =====
-- Company brand assets held in the database, not in the code repository (a stamp image in a public repo could be misused).
-- 'stamp' is printed only on issued invoices and notes.
create table public.brand_assets (
  code text primary key check (code in ('stamp')),
  mime_type text not null check (mime_type in ('image/png', 'image/jpeg')),
  data bytea not null check (octet_length(data) <= 1048576),
  sha256 text not null,
  uploaded_by uuid references public.app_users (id) default auth.uid(),
  uploaded_at timestamptz not null default now()
);

create or replace function public.brand_assets_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.log_event('brand_assets', coalesce(new.code, old.code), lower(tg_op),
    case when tg_op = 'DELETE' then null else jsonb_build_object('sha256', new.sha256, 'bytes', octet_length(new.data)) end);
  return null;
end $$;
create trigger brand_assets_audit after insert or update or delete on public.brand_assets
  for each row execute function public.brand_assets_audit();

grant select, insert, update, delete on public.brand_assets to authenticated;
grant all on public.brand_assets to service_role;
alter table public.brand_assets enable row level security;
-- Read by anyone who can read invoices (needed to render issued invoice PDFs); changed only by settings managers.
create policy brand_assets_select on public.brand_assets for select to authenticated
  using (public.has_permission('invoices.read') or public.has_permission('settings.manage'));
create policy brand_assets_write on public.brand_assets for all to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));

-- ===== 20261030000009_procurement.sql =====
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
    if auth.uid() = old.requested_by and not coalesce((select allow_self_approval from public.company_settings), false) then
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

-- ===== 20261030000010_open_access.sql =====
-- RMS open access: a small team works without role restrictions.
-- With company_settings.open_access on (the default), every active user holds every permission except the admin ones
-- (users, company settings, audit log), and people may approve their own quotations and purchase requests.
-- Turning it off falls back to the role permissions. Legal locks (issued invoices, document numbers) never change.

alter table public.company_settings add column open_access boolean not null default true;
alter table public.company_settings alter column allow_self_approval set default true;
update public.company_settings set open_access = true, allow_self_approval = true;

create or replace function public.admin_only_permission(p_code text) returns boolean
language sql immutable as $$
  select p_code in ('users.manage', 'settings.manage', 'audit.read')
$$;

create or replace function public.has_permission(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.app_users u
    where u.id = auth.uid()
      and u.is_active
      and (
        (not public.admin_only_permission(p_code)
         and coalesce((select open_access from public.company_settings), false)
         and exists (select 1 from public.permissions p where p.code = p_code))
        or exists (select 1 from public.user_roles ur join public.role_permissions rp on rp.role_id = ur.role_id
                   where ur.user_id = u.id and rp.permission_code = p_code)
      )
  )
$$;

create or replace function public.current_permissions() returns setof text
language sql stable security definer set search_path = public as $$
  select rp.permission_code
  from public.app_users u
  join public.user_roles ur on ur.user_id = u.id
  join public.role_permissions rp on rp.role_id = ur.role_id
  where u.id = auth.uid() and u.is_active
  union
  select p.code
  from public.permissions p, public.app_users u
  where u.id = auth.uid() and u.is_active
    and not public.admin_only_permission(p.code)
    and coalesce((select open_access from public.company_settings), false)
$$;

-- ===== 20261030000011_simple_quotes.sql =====
-- RMS simple quotes: a line can carry a typed rate (manual_rate). Then the price is simply quantity × rate and no
-- costing is needed. Lines without a typed rate are still priced from their costs and the revision's mark-up or margin.
-- Margin is shown only when costs were entered.

alter table public.quotation_lines add column manual_rate numeric(18, 2) check (manual_rate >= 0);

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

  -- A typed rate wins; otherwise the rate comes from the line's cost and the revision's price factor.
  update public.quotation_lines
     set sell_rate = coalesce(manual_rate, round(unit_cost * v_factor, 2)),
         sell_total = round(quantity * coalesce(manual_rate, round(unit_cost * v_factor, 2)), 2)
   where revision_id = p_revision_id
     and (sell_rate, sell_total) is distinct from
         (coalesce(manual_rate, round(unit_cost * v_factor, 2)), round(quantity * coalesce(manual_rate, round(unit_cost * v_factor, 2)), 2));

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
    gross_margin_pct = case when v_net > 0 and v_cost > 0 then round(v_gp / v_net * 100, 2) else null end
  where id = p_revision_id;
  perform set_config('rms.recalc', '', true);
end $$;
revoke all on function public.recalculate_revision(uuid) from public;

drop trigger quotation_lines_recalc on public.quotation_lines;
create trigger quotation_lines_recalc
  after insert or delete or update of quantity, material_unit_cost, labour_unit_cost, equipment_unit_cost,
    subcontract_unit_cost, other_unit_cost, manual_rate on public.quotation_lines
  for each row execute function public.quotation_lines_recalc();

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
    discount_type, discount_value, vat_code, vat_rate,
    project_name, project_location, client_rfp_reference, cc, signatory_id, cover_letter_en, cover_letter_ar,
    executive_summary_en, executive_summary_ar, general_terms_en, general_terms_ar, warranty_en, warranty_ar,
    price_display, schedule, payment_milestones, compliance)
  select quotation_id, v_prev.revision_no + 1, attention_contact_id, subject,
    greatest(valid_until, (now() at time zone 'Asia/Riyadh')::date + (select quotation_validity_days from public.company_settings)),
    scope_en, scope_ar, exclusions_en, exclusions_ar, payment_terms_en, payment_terms_ar,
    completion_period_en, completion_period_ar, internal_notes, exchange_rate_to_base,
    overhead_pct, contingency_pct, pricing_method, markup_pct, target_margin_pct,
    discount_type, discount_value, vat_code, vat_rate,
    project_name, project_location, client_rfp_reference, cc, signatory_id, cover_letter_en, cover_letter_ar,
    executive_summary_en, executive_summary_ar, general_terms_en, general_terms_ar, warranty_en, warranty_ar,
    price_display, schedule, payment_milestones, compliance
  from public.quotation_revisions where id = v_prev.id
  returning id into v_new;

  insert into public.quotation_lines (revision_id, sort_order, section, item_code, description_en, description_ar,
    unit, quantity, material_unit_cost, labour_unit_cost, equipment_unit_cost, subcontract_unit_cost, other_unit_cost, manual_rate)
  select v_new, sort_order, section, item_code, description_en, description_ar,
    unit, quantity, material_unit_cost, labour_unit_cost, equipment_unit_cost, subcontract_unit_cost, other_unit_cost, manual_rate
  from public.quotation_lines where revision_id = v_prev.id;

  perform public.recalculate_revision(v_new);
  return v_new;
end $$;
