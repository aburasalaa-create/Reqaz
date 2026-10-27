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
