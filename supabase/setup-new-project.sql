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

-- ===== 20261030000012_expenses.sql =====
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

-- ===== 20261031000013_accounting.sql =====
-- RMS accounting engine: chart of accounts, cost categories and a double-entry general ledger.
--
-- Rules
--   * Journal entries are written only by the posting functions in the database, never typed into tables by the browser
--     or calculated by AI. Every entry must balance (total debits = total credits); this is checked when the entry is
--     posted and again, deferred, when the transaction commits.
--   * Posted entries are permanent. Mistakes are corrected with a reversing entry, never by editing or deleting.
--   * Each business event (an issued invoice, a payment, an approved expense, ...) posts at most once:
--     (source_type, source_id, event) is unique among entries that are not reversals.
--   * Accounts used by the posting rules are found by their system key, so codes and names can be changed in Settings.

create type public.account_type as enum ('asset', 'liability', 'equity', 'income', 'expense');

insert into public.permissions (code, module, description) values
  ('accounting.read', 'accounting', 'View the general ledger, trial balance and bank reconciliation'),
  ('accounting.manage', 'accounting', 'Manage the chart of accounts, post manual journals and reconcile bank statements');

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on (
  (r.code in ('administrator', 'general_manager', 'finance') and p.code like 'accounting.%')
  or (r.code = 'project_management' and p.code = 'accounting.read'))
on conflict do nothing;

create table public.accounts (
  code text primary key check (code ~ '^[0-9]{3,8}$'),
  name_en text not null check (length(trim(name_en)) > 0),
  name_ar text,
  type public.account_type not null,
  system_key text unique,                 -- used by the posting rules (e.g. 'receivables'); null for user accounts
  is_bank boolean not null default false, -- bank and cash accounts: payments are received into / paid from these
  bank_name text,
  iban text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger accounts_updated before update on public.accounts for each row execute function public.set_updated_at();

insert into public.accounts (code, name_en, name_ar, type, system_key, is_bank) values
  ('1000', 'Cash on hand', 'النقدية في الصندوق', 'asset', 'cash', true),
  ('1010', 'Bank', 'البنك', 'asset', 'bank', true),
  ('1100', 'Accounts receivable', 'الذمم المدينة', 'asset', 'receivables', false),
  ('1110', 'Retention receivable', 'محتجزات لدى العملاء', 'asset', 'retention_receivable', false),
  ('1150', 'Advances to suppliers', 'دفعات مقدمة للموردين', 'asset', 'supplier_advances', false),
  ('1200', 'VAT input (recoverable)', 'ضريبة القيمة المضافة - مدخلات', 'asset', 'vat_input', false),
  ('2000', 'Accounts payable', 'الذمم الدائنة', 'liability', 'payables', false),
  ('2010', 'Retention payable to suppliers', 'محتجزات الموردين', 'liability', 'retention_payable', false),
  ('2100', 'VAT output', 'ضريبة القيمة المضافة - مخرجات', 'liability', 'vat_output', false),
  ('2150', 'Goods received not invoiced', 'بضائع مستلمة لم تصل فواتيرها', 'liability', 'grni', false),
  ('2200', 'Advances from customers', 'دفعات مقدمة من العملاء', 'liability', 'customer_advances', false),
  ('2300', 'Expense claims payable', 'مصروفات مستحقة الدفع', 'liability', 'expense_claims', false),
  ('3000', 'Owners'' equity', 'حقوق الملكية', 'equity', 'equity', false),
  ('4000', 'Contract revenue', 'إيرادات العقود', 'income', 'revenue', false),
  ('5000', 'Project costs: materials', 'تكاليف المشاريع: مواد', 'expense', 'cost_materials', false),
  ('5100', 'Project costs: subcontractors', 'تكاليف المشاريع: مقاولو الباطن', 'expense', 'cost_subcontract', false),
  ('5200', 'Project costs: labour', 'تكاليف المشاريع: عمالة', 'expense', 'cost_labour', false),
  ('5300', 'Project costs: equipment', 'تكاليف المشاريع: معدات', 'expense', 'cost_equipment', false),
  ('5900', 'Project costs: other', 'تكاليف المشاريع: أخرى', 'expense', 'cost_other', false),
  ('6000', 'General and administrative expenses', 'مصروفات عمومية وإدارية', 'expense', 'overheads', false);

-- Cost categories split project budgets and costs. Each posts to its own expense account.
create table public.cost_categories (
  code text primary key check (code ~ '^[a-z_]{2,30}$'),
  name_en text not null,
  name_ar text,
  account_code text not null references public.accounts (code),
  sort_order integer not null default 0,
  is_active boolean not null default true
);
insert into public.cost_categories (code, name_en, name_ar, account_code, sort_order) values
  ('materials', 'Materials', 'مواد', '5000', 1),
  ('subcontract', 'Subcontractors', 'مقاولو الباطن', '5100', 2),
  ('labour', 'Labour', 'عمالة', '5200', 3),
  ('equipment', 'Equipment', 'معدات', '5300', 4),
  ('other', 'Other costs', 'تكاليف أخرى', '5900', 5),
  ('general', 'Not yet allocated', 'غير موزع', '5900', 9);

create or replace function public.account_for(p_key text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  select code into v from public.accounts where system_key = p_key;
  if v is null then raise exception 'The ledger account for % is missing; check the chart of accounts', p_key using errcode = 'no_data_found'; end if;
  return v;
end $$;

-- Expense account for a cost category (project costs) or overheads when there is no project.
create or replace function public.cost_account(p_category text, p_project_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when p_project_id is null and coalesce(p_category, 'general') not in (select code from public.cost_categories where code <> 'general')
              then public.account_for('overheads')
              else coalesce((select account_code from public.cost_categories where code = coalesce(p_category, 'other')),
                            public.account_for('cost_other')) end
$$;

-- ---------------------------------------------------------------------------
-- Journal
-- ---------------------------------------------------------------------------

create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  entry_date date not null,
  source_type text not null,             -- 'invoice', 'customer_payment', 'expense', 'manual', ...
  source_id uuid,
  event text not null,                   -- 'issue', 'payment', 'approve', ...
  memo text,
  reverses_id uuid unique references public.journal_entries (id),
  total numeric(18, 2) not null check (total >= 0),
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create unique index journal_entries_once on public.journal_entries (source_type, source_id, event) where reverses_id is null and source_type <> 'manual';
create index journal_entries_source_idx on public.journal_entries (source_type, source_id);
create index journal_entries_date_idx on public.journal_entries (entry_date);

create table public.journal_lines (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.journal_entries (id),
  line_no integer not null,
  account_code text not null references public.accounts (code),
  debit numeric(18, 2) not null default 0 check (debit >= 0),
  credit numeric(18, 2) not null default 0 check (credit >= 0),
  project_id uuid references public.projects (id),
  customer_id uuid references public.customers (id),
  supplier_id uuid references public.suppliers (id),
  cost_category text references public.cost_categories (code),
  description text,
  constraint journal_lines_one_side check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);
create index journal_lines_entry_idx on public.journal_lines (entry_id);
create index journal_lines_account_idx on public.journal_lines (account_code);
create index journal_lines_project_idx on public.journal_lines (project_id, account_code);

-- The ledger is append-only. post_journal() may set an entry's total once, right after inserting its lines.
create or replace function public.journal_immutable() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and tg_table_name = 'journal_entries' and coalesce(current_setting('rms.journal_total', true), '') = old.id::text
     and (to_jsonb(new) - 'total') = (to_jsonb(old) - 'total') then
    return new;
  end if;
  raise exception 'Posted journal entries cannot be changed or deleted; post a reversing entry' using errcode = 'insufficient_privilege';
end $$;
create trigger journal_entries_immutable before update or delete on public.journal_entries for each row execute function public.journal_immutable();
create trigger journal_lines_immutable before update or delete on public.journal_lines for each row execute function public.journal_immutable();

-- Checked again at commit, so no transaction can leave an unbalanced entry behind.
create or replace function public.journal_entry_balanced() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_dr numeric; v_cr numeric; v_n integer; v_total numeric;
begin
  -- new is the row as inserted; the total set afterwards by post_journal() is read back from the table.
  select total into v_total from public.journal_entries where id = new.id;
  select coalesce(sum(debit), 0), coalesce(sum(credit), 0), count(*) into v_dr, v_cr, v_n from public.journal_lines where entry_id = new.id;
  if v_n < 2 or v_dr <> v_cr or v_dr <> v_total then
    raise exception 'Journal entry % does not balance (debits %, credits %)', new.number, v_dr, v_cr using errcode = 'check_violation';
  end if;
  return null;
end $$;
create constraint trigger journal_entries_balanced after insert on public.journal_entries
  deferrable initially deferred for each row execute function public.journal_entry_balanced();

-- Post one entry. p_lines: [{account | account_key, debit | credit | amount (+debit / −credit), project_id, customer_id,
-- supplier_id, cost_category, description}]. Zero lines are skipped; a negative debit becomes a credit and vice versa.
create or replace function public.post_journal(p_date date, p_source_type text, p_source_id uuid, p_event text, p_memo text, p_lines jsonb)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := gen_random_uuid();
  l jsonb; v_amt numeric; v_acct text; v_n integer := 0; v_dr numeric := 0; v_cr numeric := 0;
begin
  if not exists (select 1 from jsonb_array_elements(p_lines) x
                 where round(coalesce((x ->> 'debit')::numeric, 0) - coalesce((x ->> 'credit')::numeric, 0) + coalesce((x ->> 'amount')::numeric, 0), 2) <> 0) then
    return null;   -- nothing to post
  end if;
  if p_source_type <> 'manual' and exists (select 1 from public.journal_entries where source_type = p_source_type and source_id = p_source_id
                                                 and event = p_event and reverses_id is null
                                                 and not exists (select 1 from public.journal_entries r where r.reverses_id = journal_entries.id)) then
    raise exception 'This % has already been posted', replace(p_source_type, '_', ' ') using errcode = 'unique_violation';
  end if;
  insert into public.journal_entries (id, number, entry_date, source_type, source_id, event, memo, total)
  values (v_id, public.next_document_number('journal', 'JE', true, 6), p_date, p_source_type, p_source_id, p_event, p_memo, 0);
  for l in select * from jsonb_array_elements(p_lines) loop
    v_amt := round(coalesce((l ->> 'debit')::numeric, 0) - coalesce((l ->> 'credit')::numeric, 0) + coalesce((l ->> 'amount')::numeric, 0), 2);
    continue when v_amt = 0;
    v_acct := coalesce(l ->> 'account', public.account_for(l ->> 'account_key'));
    if not exists (select 1 from public.accounts where code = v_acct and is_active) then
      raise exception 'Ledger account % is not active', v_acct using errcode = 'check_violation';
    end if;
    v_n := v_n + 1;
    insert into public.journal_lines (entry_id, line_no, account_code, debit, credit, project_id, customer_id, supplier_id, cost_category, description)
    values (v_id, v_n, v_acct, greatest(v_amt, 0), greatest(-v_amt, 0), nullif(l ->> 'project_id', '')::uuid,
            nullif(l ->> 'customer_id', '')::uuid, nullif(l ->> 'supplier_id', '')::uuid, nullif(l ->> 'cost_category', ''), l ->> 'description');
    v_dr := v_dr + greatest(v_amt, 0); v_cr := v_cr + greatest(-v_amt, 0);
  end loop;
  if v_dr <> v_cr then
    raise exception 'The journal entry does not balance (debits %, credits %)', v_dr, v_cr using errcode = 'check_violation';
  end if;
  perform set_config('rms.journal_total', v_id::text, true);
  update public.journal_entries set total = v_dr where id = v_id;
  perform set_config('rms.journal_total', '', true);
  return v_id;
end $$;


-- Post the business event only if it has not been posted yet (used by triggers and the one-off back-fill).
create or replace function public.post_journal_once(p_date date, p_source_type text, p_source_id uuid, p_event text, p_memo text, p_lines jsonb)
returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.journal_entries e where e.source_type = p_source_type and e.source_id = p_source_id and e.event = p_event
             and e.reverses_id is null and not exists (select 1 from public.journal_entries r where r.reverses_id = e.id)) then
    return null;
  end if;
  return public.post_journal(p_date, p_source_type, p_source_id, p_event, p_memo, p_lines);
end $$;

-- Reverse every live entry of a source (optionally one event) with mirror-image entries dated p_date.
create or replace function public.reverse_source(p_source_type text, p_source_id uuid, p_event text, p_date date, p_memo text)
returns integer
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries%rowtype; v_id uuid; v_n integer := 0;
begin
  for e in select * from public.journal_entries j where j.source_type = p_source_type and j.source_id = p_source_id
             and (p_event is null or j.event = p_event) and j.reverses_id is null
             and not exists (select 1 from public.journal_entries r where r.reverses_id = j.id) order by created_at loop
    v_id := gen_random_uuid();
    insert into public.journal_entries (id, number, entry_date, source_type, source_id, event, memo, reverses_id, total)
    values (v_id, public.next_document_number('journal', 'JE', true, 6), p_date, e.source_type, e.source_id, e.event,
            coalesce(p_memo, 'Reversal of ' || e.number), e.id, e.total);
    insert into public.journal_lines (entry_id, line_no, account_code, debit, credit, project_id, customer_id, supplier_id, cost_category, description)
    select v_id, line_no, account_code, credit, debit, project_id, customer_id, supplier_id, cost_category, description
      from public.journal_lines where entry_id = e.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

revoke all on function public.post_journal(date, text, uuid, text, text, jsonb), public.post_journal_once(date, text, uuid, text, text, jsonb),
  public.reverse_source(text, uuid, text, date, text) from public, anon, authenticated;

-- Manual journals (opening balances, accruals, corrections) by accounting managers. Same balance rules.
create or replace function public.post_manual_journal(p_date date, p_memo text, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not public.has_permission('accounting.manage') then
    raise exception 'You do not have permission to post journals' using errcode = 'insufficient_privilege';
  end if;
  if length(trim(coalesce(p_memo, ''))) = 0 then raise exception 'Describe the journal' using errcode = 'check_violation'; end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l where l ? 'account_key') then
    raise exception 'Choose accounts by code' using errcode = 'check_violation';
  end if;
  v := public.post_journal(p_date, 'manual', gen_random_uuid(), 'manual', p_memo, p_lines);
  perform public.log_event('journal_entries', v::text, 'manual journal posted');
  return v;
end $$;

create or replace function public.reverse_manual_journal(p_entry_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.journal_entries%rowtype;
begin
  if not public.has_permission('accounting.manage') then
    raise exception 'You do not have permission to reverse journals' using errcode = 'insufficient_privilege';
  end if;
  select * into e from public.journal_entries where id = p_entry_id;
  if not found or e.source_type <> 'manual' or e.reverses_id is not null then
    raise exception 'Only manual journals can be reversed here; documents are reversed by cancelling or crediting them' using errcode = 'check_violation';
  end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'A reason is required' using errcode = 'check_violation'; end if;
  if public.reverse_source('manual', e.source_id, null, (now() at time zone 'Asia/Riyadh')::date, 'Reversal: ' || p_reason) = 0 then
    raise exception 'This journal is already reversed' using errcode = 'check_violation';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Posting rules for documents that already exist
-- ---------------------------------------------------------------------------

alter table public.customer_payments add column bank_account_code text references public.accounts (code);
alter table public.expenses add column paid_from_account text references public.accounts (code);

-- Sales invoices and notes (not proformas), on issue:
--   invoice / debit note: Dr receivables (payable), Dr retention receivable, Dr customer advances (advance deducted)
--                         Cr revenue (taxable), Cr VAT output
--   credit note:          the opposite, Cr receivables (total)
create or replace function public.post_invoice(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare i public.invoices%rowtype; s numeric;
begin
  select * into i from public.invoices where id = p_id;
  if i.status <> 'issued' or i.kind = 'proforma' then return; end if;
  s := case when i.kind = 'credit_note' then -1 else 1 end;
  perform public.post_journal_once(i.issue_date, 'invoice', i.id, 'issue', i.kind::text || ' ' || i.number, jsonb_build_array(
    jsonb_build_object('account_key', 'receivables', 'amount', s * case when i.kind = 'credit_note' then i.total_amount else i.amount_payable end,
                       'customer_id', i.customer_id, 'project_id', i.project_id),
    jsonb_build_object('account_key', 'retention_receivable', 'amount', s * i.retention_amount, 'customer_id', i.customer_id, 'project_id', i.project_id),
    jsonb_build_object('account_key', 'customer_advances', 'amount', s * i.advance_deduction, 'customer_id', i.customer_id, 'project_id', i.project_id),
    jsonb_build_object('account_key', 'revenue', 'amount', -s * i.taxable_amount, 'customer_id', i.customer_id, 'project_id', i.project_id),
    jsonb_build_object('account_key', 'vat_output', 'amount', -s * i.vat_total, 'customer_id', i.customer_id)));
end $$;

create or replace function public.invoices_post() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'draft' and new.status = 'issued' then perform public.post_invoice(new.id); end if;
  return null;
end $$;
create trigger invoices_post after update of status on public.invoices for each row execute function public.invoices_post();

-- Payments received: Dr bank, Cr receivables. Voiding reverses the entry.
create or replace function public.post_customer_payment(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p public.customer_payments%rowtype; v_proj uuid;
begin
  select * into p from public.customer_payments where id = p_id;
  select project_id into v_proj from public.invoices where id = p.invoice_id;
  perform public.post_journal_once(p.payment_date, 'customer_payment', p.id, 'payment', 'Payment ' || p.number, jsonb_build_array(
    jsonb_build_object('account', coalesce(p.bank_account_code, public.account_for('bank')), 'amount', p.amount, 'customer_id', p.customer_id, 'project_id', v_proj),
    jsonb_build_object('account_key', 'receivables', 'amount', -p.amount, 'customer_id', p.customer_id, 'project_id', v_proj)));
end $$;

create or replace function public.customer_payments_post() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.bank_account_code is not null and not exists (select 1 from public.accounts where code = new.bank_account_code and is_bank and is_active) then
      raise exception 'Choose an active bank or cash account' using errcode = 'check_violation';
    end if;
    perform public.post_customer_payment(new.id);
  elsif old.voided_at is null and new.voided_at is not null then
    perform public.reverse_source('customer_payment', new.id, null, (now() at time zone 'Asia/Riyadh')::date, 'Payment voided: ' || new.void_reason);
  end if;
  return null;
end $$;
create trigger customer_payments_post after insert or update on public.customer_payments for each row execute function public.customer_payments_post();

-- Expenses: on approval Dr cost (project cost category, or overheads) and VAT input, Cr expense claims payable;
-- when paid Dr expense claims payable, Cr bank.
create or replace function public.post_expense(p_id uuid, p_event text) returns void
language plpgsql security definer set search_path = public as $$
declare e public.expenses%rowtype; v_cat text;
begin
  select * into e from public.expenses where id = p_id;
  v_cat := case when e.category in (select code from public.cost_categories) then e.category when e.project_id is not null then 'other' end;
  if p_event = 'approve' then
    perform public.post_journal_once(coalesce(e.expense_date, (now() at time zone 'Asia/Riyadh')::date), 'expense', e.id, 'approve',
      'Expense ' || e.number, jsonb_build_array(
      jsonb_build_object('account', public.cost_account(v_cat, e.project_id), 'amount', e.amount, 'project_id', e.project_id,
                         'supplier_id', e.supplier_id, 'cost_category', case when e.project_id is not null then v_cat end, 'description', e.description),
      jsonb_build_object('account_key', 'vat_input', 'amount', e.vat_amount, 'supplier_id', e.supplier_id),
      jsonb_build_object('account_key', 'expense_claims', 'amount', -(e.amount + e.vat_amount), 'supplier_id', e.supplier_id, 'project_id', e.project_id)));
  elsif p_event = 'pay' then
    perform public.post_journal_once(coalesce((e.paid_at at time zone 'Asia/Riyadh')::date, (now() at time zone 'Asia/Riyadh')::date), 'expense', e.id, 'pay',
      'Expense paid ' || e.number, jsonb_build_array(
      jsonb_build_object('account_key', 'expense_claims', 'amount', e.amount + e.vat_amount, 'supplier_id', e.supplier_id, 'project_id', e.project_id),
      jsonb_build_object('account', coalesce(e.paid_from_account, public.account_for('bank')), 'amount', -(e.amount + e.vat_amount),
                         'supplier_id', e.supplier_id, 'project_id', e.project_id)));
  end if;
end $$;

create or replace function public.expenses_post() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = old.status then return null; end if;
  if new.status = 'approved' then perform public.post_expense(new.id, 'approve');
  elsif new.status = 'paid' then
    if new.paid_from_account is not null and not exists (select 1 from public.accounts where code = new.paid_from_account and is_bank and is_active) then
      raise exception 'Choose an active bank or cash account' using errcode = 'check_violation';
    end if;
    perform public.post_expense(new.id, 'pay');
  end if;
  return null;
end $$;
create trigger expenses_post after update of status on public.expenses for each row execute function public.expenses_post();

-- Post the documents that were issued, paid or approved before the ledger existed.
do $$
declare r record;
begin
  for r in select id from public.invoices where status = 'issued' and kind <> 'proforma' order by issued_at loop
    perform public.post_invoice(r.id);
  end loop;
  for r in select id, voided_at from public.customer_payments order by created_at loop
    perform public.post_customer_payment(r.id);
    if r.voided_at is not null then perform public.reverse_source('customer_payment', r.id, null, (r.voided_at at time zone 'Asia/Riyadh')::date, 'Payment voided'); end if;
  end loop;
  for r in select id, status from public.expenses where status in ('approved', 'paid') order by created_at loop
    perform public.post_expense(r.id, 'approve');
    if r.status = 'paid' then perform public.post_expense(r.id, 'pay'); end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------------

create view public.account_balances with (security_invoker = true) as
  select a.code, a.name_en, a.name_ar, a.type, a.is_bank, a.system_key,
         coalesce(sum(l.debit), 0) as debit, coalesce(sum(l.credit), 0) as credit,
         coalesce(sum(l.debit - l.credit), 0) as balance
    from public.accounts a left join public.journal_lines l on l.account_code = a.code
   group by a.code;

-- ---------------------------------------------------------------------------
-- Audit, grants and row-level security
-- ---------------------------------------------------------------------------

create trigger audit_accounts after insert or update or delete on public.accounts for each row execute function public.audit_trigger();
create trigger audit_cost_categories after insert or update or delete on public.cost_categories for each row execute function public.audit_trigger();

grant select on public.accounts, public.cost_categories, public.journal_entries, public.journal_lines, public.account_balances to authenticated;
grant insert, update on public.accounts, public.cost_categories to authenticated;
grant all on public.accounts, public.cost_categories, public.journal_entries, public.journal_lines to service_role;
grant select on public.account_balances to service_role;
revoke execute on function public.post_manual_journal(date, text, jsonb), public.reverse_manual_journal(uuid, text) from public, anon;
grant execute on function public.post_manual_journal(date, text, jsonb), public.reverse_manual_journal(uuid, text) to authenticated;

alter table public.accounts enable row level security;
alter table public.cost_categories enable row level security;
alter table public.journal_entries enable row level security;
alter table public.journal_lines enable row level security;

-- Everyone who works in the system can see account and category names (needed for pickers); balances need accounting.read.
create policy accounts_select on public.accounts for select to authenticated using (public.is_active_user());
create policy accounts_write on public.accounts for insert to authenticated with check (public.has_permission('accounting.manage'));
create policy accounts_update on public.accounts for update to authenticated
  using (public.has_permission('accounting.manage')) with check (public.has_permission('accounting.manage'));
create policy cost_categories_select on public.cost_categories for select to authenticated using (public.is_active_user());
create policy cost_categories_write on public.cost_categories for insert to authenticated with check (public.has_permission('accounting.manage'));
create policy cost_categories_update on public.cost_categories for update to authenticated
  using (public.has_permission('accounting.manage')) with check (public.has_permission('accounting.manage'));
create policy journal_entries_select on public.journal_entries for select to authenticated using (public.has_permission('accounting.read'));
create policy journal_lines_select on public.journal_lines for select to authenticated using (public.has_permission('accounting.read'));

-- A system account keeps its type and key so the posting rules stay correct.
create or replace function public.accounts_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if new.code <> old.code then raise exception 'An account code cannot change' using errcode = 'check_violation'; end if;
    if old.system_key is not null and (new.system_key is distinct from old.system_key or new.type <> old.type or not new.is_active) then
      raise exception 'This account is used by the automatic postings; only its name and bank details can change' using errcode = 'check_violation';
    end if;
  elsif new.system_key is not null then
    raise exception 'System accounts are created by the system' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger accounts_guard before insert or update on public.accounts for each row execute function public.accounts_guard();

-- ===== 20261031000014_customer_pos_and_budgets.sql =====
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

-- ===== 20261031000015_procurement_cycle.sql =====
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

-- ===== 20261031000016_customer_billing.sql =====
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

-- ===== 20261031000017_bank_and_documents.sql =====
-- RMS bank reconciliation and document versions.
--
-- Bank reconciliation
--   * Statement lines are entered or pasted per bank account (+ money in, − money out).
--   * Each statement line is matched to one ledger line on the same bank account with the same amount, or a new journal is
--     posted from it (bank charges, interest) against an account the person chooses. A ledger line can be matched once.
--   * Reconciled: statement balance = ledger balance − unmatched ledger items + unmatched statement items.
--
-- Documents
--   * Attachments can be stored against customer orders, supplier quotations, goods receipts, supplier invoices, budget
--     changes and variations, with a document type.
--   * Uploading a new version keeps the old one (marked superseded) so the history is never lost.

create table public.bank_statement_lines (
  id uuid primary key default gen_random_uuid(),
  account_code text not null references public.accounts (code),
  txn_date date not null,
  description text not null,
  reference text,
  amount numeric(18, 2) not null check (amount <> 0),
  journal_line_id uuid unique references public.journal_lines (id),
  matched_by uuid references public.app_users (id),
  matched_at timestamptz,
  created_by uuid references public.app_users (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index bank_statement_lines_account_idx on public.bank_statement_lines (account_code, txn_date);

create or replace function public.bank_statement_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not public.has_permission('accounting.manage') then
      raise exception 'You do not have permission to enter bank statements' using errcode = 'insufficient_privilege';
    end if;
    if not exists (select 1 from public.accounts where code = new.account_code and is_bank) then
      raise exception 'Choose a bank or cash account' using errcode = 'check_violation';
    end if;
    new.journal_line_id := null; new.matched_by := null; new.matched_at := null;
    return new;
  end if;
  if coalesce(current_setting('rms.bank_match', true), '') <> coalesce(new.id, old.id)::text then
    if tg_op = 'DELETE' and old.journal_line_id is null then return old; end if;
    raise exception 'Use match or unmatch; matched statement lines cannot be changed or deleted' using errcode = 'insufficient_privilege';
  end if;
  return coalesce(new, old);
end $$;
create trigger bank_statement_lines_guard before insert or update or delete on public.bank_statement_lines
  for each row execute function public.bank_statement_lines_guard();

create or replace function public.match_bank_line(p_statement_line_id uuid, p_journal_line_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s public.bank_statement_lines%rowtype; j public.journal_lines%rowtype;
begin
  if not public.has_permission('accounting.manage') then
    raise exception 'You do not have permission to reconcile' using errcode = 'insufficient_privilege';
  end if;
  select * into s from public.bank_statement_lines where id = p_statement_line_id for update;
  if not found then raise exception 'Statement line not found' using errcode = 'no_data_found'; end if;
  if s.journal_line_id is not null then raise exception 'This statement line is already matched' using errcode = 'check_violation'; end if;
  select * into j from public.journal_lines where id = p_journal_line_id;
  if not found or j.account_code <> s.account_code then
    raise exception 'Match it to an entry on the same bank account' using errcode = 'check_violation';
  end if;
  if j.debit - j.credit <> s.amount then
    raise exception 'The amounts are different (statement %, ledger %)', s.amount, j.debit - j.credit using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bank_statement_lines where journal_line_id = p_journal_line_id) then
    raise exception 'That ledger entry is already matched to another statement line' using errcode = 'check_violation';
  end if;
  perform set_config('rms.bank_match', s.id::text, true);
  update public.bank_statement_lines set journal_line_id = p_journal_line_id, matched_by = auth.uid(), matched_at = now() where id = s.id;
  perform set_config('rms.bank_match', '', true);
end $$;

create or replace function public.unmatch_bank_line(p_statement_line_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_permission('accounting.manage') then
    raise exception 'You do not have permission to reconcile' using errcode = 'insufficient_privilege';
  end if;
  perform set_config('rms.bank_match', p_statement_line_id::text, true);
  update public.bank_statement_lines set journal_line_id = null, matched_by = null, matched_at = null where id = p_statement_line_id;
  perform set_config('rms.bank_match', '', true);
end $$;

-- Post a journal for a statement item not yet in the books (bank charges, interest, ...) and match it.
create or replace function public.post_bank_line(p_statement_line_id uuid, p_account_code text, p_memo text) returns uuid
language plpgsql security definer set search_path = public as $$
declare s public.bank_statement_lines%rowtype; v_entry uuid; v_line uuid;
begin
  if not public.has_permission('accounting.manage') then
    raise exception 'You do not have permission to reconcile' using errcode = 'insufficient_privilege';
  end if;
  select * into s from public.bank_statement_lines where id = p_statement_line_id for update;
  if s.journal_line_id is not null then raise exception 'This statement line is already matched' using errcode = 'check_violation'; end if;
  if p_account_code = s.account_code or not exists (select 1 from public.accounts where code = p_account_code and is_active) then
    raise exception 'Choose the other account for this item' using errcode = 'check_violation';
  end if;
  v_entry := public.post_journal(s.txn_date, 'bank_statement', s.id, 'post', coalesce(nullif(trim(p_memo), ''), s.description), jsonb_build_array(
    jsonb_build_object('account', s.account_code, 'amount', s.amount, 'description', s.description),
    jsonb_build_object('account', p_account_code, 'amount', -s.amount, 'description', s.description)));
  select id into v_line from public.journal_lines where entry_id = v_entry and account_code = s.account_code;
  perform set_config('rms.bank_match', s.id::text, true);
  update public.bank_statement_lines set journal_line_id = v_line, matched_by = auth.uid(), matched_at = now() where id = s.id;
  perform set_config('rms.bank_match', '', true);
  return v_entry;
end $$;

grant select, insert, delete on public.bank_statement_lines to authenticated;
grant all on public.bank_statement_lines to service_role;
revoke execute on function public.match_bank_line(uuid, uuid), public.unmatch_bank_line(uuid), public.post_bank_line(uuid, text, text) from public, anon;
grant execute on function public.match_bank_line(uuid, uuid), public.unmatch_bank_line(uuid), public.post_bank_line(uuid, text, text) to authenticated;
alter table public.bank_statement_lines enable row level security;
create policy bank_statement_lines_select on public.bank_statement_lines for select to authenticated using (public.has_permission('accounting.read'));
create policy bank_statement_lines_insert on public.bank_statement_lines for insert to authenticated with check (public.has_permission('accounting.manage'));
create policy bank_statement_lines_delete on public.bank_statement_lines for delete to authenticated using (public.has_permission('accounting.manage'));
create trigger audit_bank_statement_lines after insert or update or delete on public.bank_statement_lines for each row execute function public.audit_trigger();

-- ---------------------------------------------------------------------------
-- Documents: more record types, document type and versions
-- ---------------------------------------------------------------------------

alter table public.attachments
  add column document_type text check (document_type in ('customer_po', 'supplier_quotation', 'supplier_po', 'requisition', 'goods_received_note',
                                                         'supplier_invoice', 'delivery_note', 'contract', 'amendment', 'specification', 'receipt', 'other')),
  add column version integer not null default 1 check (version >= 1),
  add column replaces_id uuid references public.attachments (id),
  add column superseded_at timestamptz;
create unique index attachments_one_successor on public.attachments (replaces_id) where replaces_id is not null;

alter table public.attachments drop constraint attachments_entity_type_check;
alter table public.attachments add constraint attachments_entity_type_check
  check (entity_type in ('customer', 'opportunity', 'tender', 'quotation', 'quotation_revision', 'contract', 'project', 'invoice',
                         'purchase_request', 'purchase_order', 'expense', 'customer_po', 'supplier_quote', 'goods_receipt',
                         'supplier_invoice', 'budget_change', 'variation'));

-- Attachments stay a register; the only changes are soft deletion and being superseded by a newer version (once).
create or replace function public.attachments_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Attachments cannot be deleted; mark them deleted instead' using errcode = 'insufficient_privilege';
  end if;
  if (to_jsonb(new) - 'deleted_at' - 'deleted_by' - 'superseded_at') <> (to_jsonb(old) - 'deleted_at' - 'deleted_by' - 'superseded_at')
     or (old.superseded_at is not null and new.superseded_at is distinct from old.superseded_at) then
    raise exception 'Attachment metadata is immutable' using errcode = 'insufficient_privilege';
  end if;
  if new.deleted_at is distinct from old.deleted_at then
    if old.deleted_at is not null then
      raise exception 'Attachment already deleted' using errcode = 'check_violation';
    end if;
    if old.is_system_generated then
      raise exception 'System-generated documents cannot be deleted' using errcode = 'insufficient_privilege';
    end if;
  end if;
  return new;
end $$;

-- A new version: same record, version + 1; the previous file is kept and marked superseded.
create or replace function public.attachments_versioning() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.attachments%rowtype;
begin
  if new.replaces_id is null then new.version := 1; return new; end if;
  select * into p from public.attachments where id = new.replaces_id;
  if not found or p.entity_type <> new.entity_type or p.entity_id <> new.entity_id then
    raise exception 'A new version must belong to the same record' using errcode = 'check_violation';
  end if;
  if p.superseded_at is not null or p.deleted_at is not null then
    raise exception 'That file already has a newer version' using errcode = 'check_violation';
  end if;
  new.version := p.version + 1;
  new.document_type := coalesce(new.document_type, p.document_type);
  update public.attachments set superseded_at = now() where id = p.id;
  return new;
end $$;
create trigger attachments_versioning before insert on public.attachments for each row execute function public.attachments_versioning();

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
    when 'expense' then public.has_permission('expenses.write') or public.has_permission('expenses.read')
    when 'customer_po' then public.has_permission(case when p_write then 'customer_pos.write' else 'customer_pos.read' end)
    when 'supplier_quote' then public.has_permission(case when p_write then 'procurement.order' else 'procurement.read' end)
    when 'goods_receipt' then public.has_permission(case when p_write then 'procurement.request' else 'procurement.read' end)
                              or (p_write and public.has_permission('procurement.order'))
    when 'supplier_invoice' then public.has_permission(case when p_write then 'procurement.order' else 'procurement.read' end)
                                 or public.has_permission(case when p_write then 'payments.write' else 'invoices.read' end)
    when 'budget_change' then public.has_permission(case when p_write then 'budgets.write' else 'projects.read' end)
    when 'variation' then public.has_permission(case when p_write then 'budgets.write' else 'projects.read' end)
    else false end
$$;
