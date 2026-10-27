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
