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
