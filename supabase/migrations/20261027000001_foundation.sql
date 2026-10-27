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
