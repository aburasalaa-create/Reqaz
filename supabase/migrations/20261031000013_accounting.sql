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
