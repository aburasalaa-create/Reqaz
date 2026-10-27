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
