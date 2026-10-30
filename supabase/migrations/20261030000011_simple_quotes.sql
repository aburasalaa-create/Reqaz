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
