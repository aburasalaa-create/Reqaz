-- DEVELOPMENT SEED ONLY. Never run against staging-with-real-data or production.
-- Creates sample users (one per role), customers, opportunities, a tender and templates.

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-4000-8000-000000000001', 'admin@reqaz.test', '{"full_name":"Alaa Admin"}'),
  ('00000000-0000-4000-8000-000000000002', 'gm@reqaz.test', '{"full_name":"Khalid General Manager"}'),
  ('00000000-0000-4000-8000-000000000003', 'sales@reqaz.test', '{"full_name":"Sara Sales"}'),
  ('00000000-0000-4000-8000-000000000004', 'estimator@reqaz.test', '{"full_name":"Omar Estimator"}'),
  ('00000000-0000-4000-8000-000000000005', 'pm@reqaz.test', '{"full_name":"Faisal Project Manager"}'),
  ('00000000-0000-4000-8000-000000000006', 'site@reqaz.test', '{"full_name":"Yousef Site Engineer"}'),
  ('00000000-0000-4000-8000-000000000007', 'finance@reqaz.test', '{"full_name":"Noura Finance"}'),
  ('00000000-0000-4000-8000-000000000008', 'procurement@reqaz.test', '{"full_name":"Hassan Procurement"}');

update public.app_users set full_name_ar = case email
  when 'admin@reqaz.test' then 'علاء المسؤول'
  when 'gm@reqaz.test' then 'خالد المدير العام'
  when 'sales@reqaz.test' then 'سارة المبيعات'
  when 'estimator@reqaz.test' then 'عمر المقدّر'
  when 'pm@reqaz.test' then 'فيصل مدير المشروع'
  when 'site@reqaz.test' then 'يوسف مهندس الموقع'
  when 'finance@reqaz.test' then 'نورة المالية'
  when 'procurement@reqaz.test' then 'حسن المشتريات' end;

-- admin@ became administrator automatically as the first user.
insert into public.user_roles (user_id, role_id)
select u.id, r.id from public.app_users u join public.roles r on r.code = case u.email
  when 'gm@reqaz.test' then 'general_manager'
  when 'sales@reqaz.test' then 'sales'
  when 'estimator@reqaz.test' then 'estimation'
  when 'pm@reqaz.test' then 'project_management'
  when 'site@reqaz.test' then 'site_engineering'
  when 'finance@reqaz.test' then 'finance'
  when 'procurement@reqaz.test' then 'procurement' end;

-- Placeholder VAT number for development only; the real one is entered in Settings.
update public.company_settings set vat_number = '300000000000003';

-- Data entered as the sales user so audit and ownership look realistic.
begin;
do $$ begin perform set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000003","role":"authenticated"}', true); end $$;

insert into public.customers (id, party_type, name_en, name_ar, vat_number, cr_number, email, phone, building_number, street, district, city, postal_code)
values
  ('10000000-0000-4000-8000-000000000001', 'company', 'Al Noor Real Estate Development', 'شركة النور للتطوير العقاري', '310000000000003', '1010101010',
   'projects@alnoor.test', '+966 11 111 1111', '1234', 'King Fahd Road', 'Al Olaya', 'Riyadh', '12211'),
  ('10000000-0000-4000-8000-000000000002', 'government', 'Ministry of Municipal Affairs — Riyadh Branch', 'وزارة الشؤون البلدية - فرع الرياض', null, null,
   'tenders@momra.test', '+966 11 222 2222', null, null, null, 'Riyadh', null),
  ('10000000-0000-4000-8000-000000000003', 'company', 'Gulf Logistics Park Co.', 'شركة حديقة الخليج اللوجستية', '311111111111113', '2050000000',
   'facilities@gulflog.test', '+966 13 333 3333', '77', 'Industrial Road', '2nd Industrial City', 'Dammam', '34332');

insert into public.contacts (customer_id, full_name, position, email, phone, is_primary) values
  ('10000000-0000-4000-8000-000000000001', 'Eng. Fahad Al-Qahtani', 'Projects Director', 'fahad@alnoor.test', '+966 50 000 0001', true),
  ('10000000-0000-4000-8000-000000000003', 'Mona Al-Harbi', 'Facilities Manager', 'mona@gulflog.test', '+966 50 000 0003', true);

insert into public.opportunities (id, title, customer_id, source, stage, service_type, location, expected_value, win_probability, expected_close_date, description)
values
  ('20000000-0000-4000-8000-000000000001', 'Villa compound — structural works', '10000000-0000-4000-8000-000000000001', 'referral', 'tender_received',
   'Civil & structural', 'North Riyadh', 4800000, 40, current_date + 45, '12 villas, RC frame, 2 floors + annex'),
  ('20000000-0000-4000-8000-000000000002', 'Warehouse extension 2,000 m²', '10000000-0000-4000-8000-000000000003', 'email', 'qualified',
   'Steel structures', 'Dammam 2nd Industrial City', 2100000, 30, current_date + 60, null),
  ('20000000-0000-4000-8000-000000000003', 'Park landscaping and irrigation', '10000000-0000-4000-8000-000000000002', 'manual', 'new_lead',
   'Landscaping', 'Riyadh', 900000, 10, current_date + 90, null);

insert into public.opportunities (title, prospect_company, prospect_contact, prospect_email, source, stage, service_type)
values ('Office fit-out enquiry', 'Desert Rose Trading', 'Hassan Ali', 'hassan@desertrose.test', 'website', 'new_lead', 'Fit-out');

insert into public.tenders (opportunity_id, client_reference, title, issue_date, submission_deadline, site_visit_at, bid_bond_required, bid_bond_amount)
values ('20000000-0000-4000-8000-000000000001', 'ANRED-T-2026-014', 'Structural works for villa compound Phase 1',
        current_date - 5, now() + interval '12 days', now() + interval '3 days', true, 96000);

insert into public.follow_ups (opportunity_id, type, subject, due_at) values
  ('20000000-0000-4000-8000-000000000002', 'call', 'Confirm warehouse drawings received', now() - interval '1 day'),
  ('20000000-0000-4000-8000-000000000001', 'site_visit', 'Site visit with structural engineer', now() + interval '3 days');

insert into public.leads (source, external_id, contact_name, company_name, email, phone, service_interest, message)
values ('website', 'wp-demo-1001', 'Reem Al-Saud', 'Riyadh Clinics Group', 'reem@clinics.test', '+966 55 000 1001',
        'Renovation', 'We need a quotation to renovate two clinic branches (approx. 600 m² each).');
commit;

begin;
do $$ begin perform set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000004","role":"authenticated"}', true); end $$;
insert into public.boq_templates (id, name, description) values
  ('30000000-0000-4000-8000-000000000001', 'Villa — RC structure (per villa)', 'Typical 2-storey villa structural BOQ');
insert into public.boq_template_items (template_id, sort_order, section, item_code, description_en, description_ar, unit, quantity,
  material_unit_cost, labour_unit_cost, equipment_unit_cost, subcontract_unit_cost, other_unit_cost) values
  ('30000000-0000-4000-8000-000000000001', 10, 'Earthworks', '1.1', 'Excavation for foundations', 'حفر الأساسات', 'm3', 420, 0, 6, 14, 0, 0),
  ('30000000-0000-4000-8000-000000000001', 20, 'Earthworks', '1.2', 'Backfill and compaction', 'ردم ودمك', 'm3', 300, 8, 5, 7, 0, 0),
  ('30000000-0000-4000-8000-000000000001', 30, 'Concrete', '2.1', 'Plain concrete blinding C15', 'خرسانة عادية للنظافة', 'm3', 35, 230, 30, 10, 0, 0),
  ('30000000-0000-4000-8000-000000000001', 40, 'Concrete', '2.2', 'Reinforced concrete C35 footings incl. rebar', 'خرسانة مسلحة للقواعد شاملة الحديد', 'm3', 140, 520, 85, 25, 0, 0),
  ('30000000-0000-4000-8000-000000000001', 50, 'Concrete', '2.3', 'RC columns, beams and slabs', 'أعمدة وجسور وبلاطات خرسانية مسلحة', 'm3', 260, 560, 140, 40, 0, 0),
  ('30000000-0000-4000-8000-000000000001', 60, 'Waterproofing', '3.1', 'Bituminous waterproofing to foundations', 'عزل مائي بيتوميني للأساسات', 'm2', 650, 0, 0, 0, 22, 0),
  ('30000000-0000-4000-8000-000000000001', 70, 'General', '9.1', 'Site mobilisation, insurance and temporary facilities', 'التجهيز والتأمين والمرافق المؤقتة', 'LS', 1, 0, 0, 0, 0, 18000);

insert into public.quotation_templates (name, scope_en, scope_ar, exclusions_en, exclusions_ar, payment_terms_en, payment_terms_ar, completion_period_en, completion_period_ar)
values ('Standard construction terms',
  'Supply of all materials, labour and equipment to execute the works listed in the bill of quantities, in accordance with the drawings and specifications provided.',
  'توريد جميع المواد والعمالة والمعدات لتنفيذ الأعمال الواردة في جدول الكميات وفقاً للمخططات والمواصفات المقدمة.',
  'Permits and authority fees; MEP works; any work not explicitly listed.',
  'التصاريح ورسوم الجهات الحكومية؛ الأعمال الكهروميكانيكية؛ أي أعمال غير مذكورة صراحة.',
  '20% advance against an advance payment guarantee; monthly progress payments within 30 days; 10% retention released at handover.',
  'دفعة مقدمة 20% مقابل ضمان دفعة مقدمة؛ دفعات شهرية حسب الإنجاز خلال 30 يوماً؛ محتجزات 10% تصرف عند التسليم.',
  '8 months from site handover.', '8 أشهر من تاريخ استلام الموقع.');
commit;

-- Sample proposal in Reqaz's format (fictional client data): lump sum per main item with lettered sub-items.
begin;
do $$ begin perform set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000004","role":"authenticated"}', true); end $$;
do $$
declare q uuid; r uuid;
begin
  q := public.create_quotation('20000000-0000-4000-8000-000000000002', 'Warehouse Extension & New Loading Dock', null, null, 'SAR');
  update public.quotations set reference_prefix = 'GLP/DMM271026-01' where id = q;
  select id into r from public.quotation_revisions where quotation_id = q and revision_no = 0;
  update public.quotation_revisions set
    attention_contact_id = (select id from public.contacts where customer_id = '10000000-0000-4000-8000-000000000003' and is_primary),
    subject = 'Warehouse Extension & New Loading Dock',
    project_name = 'Warehouse B extension 2,000 m² and loading dock',
    project_location = 'Dammam – 2nd Industrial City',
    client_rfp_reference = 'GLP-RFQ-2026-031',
    cc = 'Eng. Saad Al-Dossary',
    valid_until = current_date + 90,
    price_display = 'lump_sum_sections',
    overhead_pct = 10, contingency_pct = 3, pricing_method = 'margin', target_margin_pct = 15,
    cover_letter_en = E'Dear Madam,\n\nWith reference to your request for quotation GLP-RFQ-2026-031 for the extension of Warehouse B and the construction of a new loading dock, we are pleased to submit our technical and commercial proposal.\n\nOur offer covers mobilisation, earthworks, foundations, the pre-engineered steel structure, cladding, the loading dock and handover documentation.\n\nREQAZ appreciates the opportunity and hopes our proposal meets your expectations. Please do not hesitate to contact me directly should you have any questions.',
    executive_summary_en = 'The following pages outline the scope of work and the lump sum price for the extension of Warehouse B by 2,000 m² and a new four-bay loading dock at Gulf Logistics Park, Dammam.',
    scope_en = E'Mobilisation, site establishment and HSE set-up\nEarthworks, excavation and compaction\nRC foundations and ground-bearing slab\nPre-engineered steel structure, roof and wall cladding\nLoading dock with four levellers and canopy\nTesting, as-built drawings, handover and demobilisation',
    general_terms_en = E'Any additional work to be agreed upon in writing.\nPrices are based on the RFQ drawings; any change after design approval is treated as a variation.\nDelays in permits or approvals extend the programme accordingly.\nPermanent power and water points to be provided by the client within 50 m of the work area.',
    exclusions_en = E'Authority fees and permits\nFire-fighting and MEP works\nRacking and material-handling equipment',
    completion_period_en = '120 working days from approval, advance payment and site handover.',
    warranty_en = '12 months defects liability from the date of handover.',
    payment_terms_en = 'As per the payment milestones below.',
    schedule = '[{"label":"Start","description":"PO, advance payment and site handover","duration":"-"},
                 {"label":"Milestone 1","description":"Mobilisation, shop drawings and approvals","duration":"20 days"},
                 {"label":"Milestone 2","description":"Earthworks, foundations and slab","duration":"40 days"},
                 {"label":"Milestone 3","description":"Steel structure, cladding and loading dock","duration":"45 days"},
                 {"label":"Milestone 4","description":"Testing, as-built drawings and handover","duration":"15 days"}]',
    payment_milestones = '[{"description":"Advance payment on signing the contract","percent":20},
                           {"description":"Milestone 2 – foundations and slab completed","percent":30},
                           {"description":"Milestone 3 – structure and cladding completed","percent":35},
                           {"description":"Milestone 4 – testing and handover","percent":10},
                           {"description":"Final – as-built approval","percent":5}]',
    compliance = '[{"ref":"2.1","requirement":"Contractor registered and classified in KSA","status":"Comply"},
                   {"ref":"3.4","requirement":"Steel structure designed to SBC 301 wind loads","status":"Comply"},
                   {"ref":"5.0","requirement":"HSE plan and method statements before mobilisation","status":"Comply"}]'
  where id = r;
  insert into public.quotation_lines (revision_id, sort_order, section, description_en, description_ar, unit, quantity,
    material_unit_cost, labour_unit_cost, equipment_unit_cost, subcontract_unit_cost, other_unit_cost) values
  (r, 10, 'Mobilisation & site establishment', 'Site offices, fencing and signage', 'مكاتب الموقع والسياج واللوحات', 'LS', 1, 0, 0, 0, 0, 24000),
  (r, 20, 'Mobilisation & site establishment', 'HSE set-up and insurance', 'تجهيزات السلامة والتأمين', 'LS', 1, 0, 0, 0, 0, 16000),
  (r, 30, 'Earthworks & foundations', 'Excavation and compaction', 'الحفر والدمك', 'm3', 1800, 0, 8, 14, 0, 0),
  (r, 40, 'Earthworks & foundations', 'RC isolated footings and tie beams C35', 'قواعد منفصلة وميد خرسانية C35', 'm3', 220, 540, 90, 25, 0, 0),
  (r, 50, 'Earthworks & foundations', 'Ground-bearing slab 200 mm with mesh', 'بلاطة أرضية 200 مم مع شبك', 'm2', 2000, 95, 30, 8, 0, 0),
  (r, 60, 'Steel structure & cladding', 'Pre-engineered steel structure', 'هيكل معدني مسبق التصميم', 'ton', 85, 0, 0, 0, 7800, 0),
  (r, 70, 'Steel structure & cladding', 'Insulated roof and wall sandwich panels', 'ألواح ساندوتش معزولة للسقف والجدران', 'm2', 3900, 0, 0, 0, 115, 0),
  (r, 80, 'Loading dock', 'Hydraulic dock levellers with seals', 'منصات تحميل هيدروليكية مع العوازل', 'no', 4, 0, 0, 0, 38000, 0),
  (r, 90, 'Loading dock', 'Dock canopy and bollards', 'مظلة الرصيف والمصدات', 'LS', 1, 0, 0, 0, 62000, 0),
  (r, 100, 'Testing & handover', 'Testing, as-built drawings and O&M manuals', 'الاختبارات والمخططات النهائية وأدلة التشغيل', 'LS', 1, 0, 0, 0, 0, 18000);
end $$;
commit;
