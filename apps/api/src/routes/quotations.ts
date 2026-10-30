import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { insertRow, many, one, type Db, type Tx } from '../db.js';
import { HttpError, notFound } from '../errors.js';
import type { Storage } from '../storage.js';
import { newStorageKey, sha256 } from '../storage.js';
import type { PdfRenderer } from '../pdf/renderer.js';
import { renderQuotationHtml, type PdfLanguage } from '../pdf/quotation.js';
import { decimal, getOr404, idParam, listQuery, optDate, optText, optUuid, reqText, tx, updateOrFail } from './util.js';

const revisionBody = z.object({
  attention_contact_id: optUuid,
  subject: optText,
  valid_until: optDate,
  scope_en: optText, scope_ar: optText,
  exclusions_en: optText, exclusions_ar: optText,
  payment_terms_en: optText, payment_terms_ar: optText,
  completion_period_en: optText, completion_period_ar: optText,
  internal_notes: optText,
  exchange_rate_to_base: decimal.optional(),
  overhead_pct: decimal.optional(),
  contingency_pct: decimal.optional(),
  pricing_method: z.enum(['markup', 'margin']).optional(),
  markup_pct: decimal.optional(),
  target_margin_pct: decimal.optional(),
  discount_type: z.enum(['none', 'percent', 'amount']).optional(),
  discount_value: decimal.optional(),
  vat_code: z.string().max(10).optional(),
  project_name: optText, project_location: optText, client_rfp_reference: optText, cc: optText, signatory_id: optUuid,
  cover_letter_en: optText, cover_letter_ar: optText, executive_summary_en: optText, executive_summary_ar: optText,
  general_terms_en: optText, general_terms_ar: optText, warranty_en: optText, warranty_ar: optText,
  price_display: z.enum(['itemised', 'lump_sum_sections']).optional(),
  schedule: z.array(z.object({ label: z.string().trim().max(100), description: z.string().trim().max(500), duration: z.string().trim().max(50) }).strict()).max(50).optional(),
  payment_milestones: z.array(z.object({ description: z.string().trim().min(1).max(500), percent: z.coerce.number().min(0).max(100) }).strict()).max(30).optional(),
  compliance: z.array(z.object({ ref: z.string().trim().max(50), requirement: z.string().trim().min(1).max(1000), status: z.string().trim().max(50) }).strict()).max(200).optional(),
}).strict();

const lineBody = z.object({
  sort_order: z.coerce.number().int().optional(),
  section: optText,
  item_code: optText,
  description_en: reqText(2000),
  description_ar: optText,
  unit: z.string().trim().min(1).max(20).optional(),
  quantity: decimal.optional(),
  material_unit_cost: decimal.optional(),
  labour_unit_cost: decimal.optional(),
  equipment_unit_cost: decimal.optional(),
  subcontract_unit_cost: decimal.optional(),
  other_unit_cost: decimal.optional(),
  manual_rate: z.union([z.literal(''), z.null(), decimal]).optional().transform((v) => (v === '' ? null : v)),
}).strict();

const TRANSITIONS = {
  submit_for_approval: { from: 'draft', to: 'pending_approval' },
  withdraw: { from: 'pending_approval', to: 'draft' },
  reject: { from: 'pending_approval', to: 'draft' },
  approve: { from: 'pending_approval', to: 'approved' },
  mark_submitted: { from: 'approved', to: 'submitted' },
} as const;

export async function loadRevisionDocument(t: Tx, revisionId: string) {
  const rev = await getOr404<any>(t, `
    select r.*, q.number as quotation_number, q.title as quotation_title, q.currency, q.status as quotation_status,
           q.customer_id, q.opportunity_id, q.tender_id,
           pu.full_name as prepared_by_name, au.full_name as approved_by_name
    from public.quotation_revisions r
    join public.quotations q on q.id = r.quotation_id
    left join public.app_users pu on pu.id = r.prepared_by
    left join public.app_users au on au.id = r.approved_by
    where r.id = $1`, [revisionId], 'Quotation revision');
  const lines = await many(t, 'select * from public.quotation_lines where revision_id = $1 order by sort_order, created_at', [revisionId]);
  const customer = await one(t, 'select * from public.customers where id = $1', [rev.customer_id]);
  const contact = rev.attention_contact_id ? await one(t, 'select * from public.contacts where id = $1', [rev.attention_contact_id]) : null;
  const company = await one(t, 'select * from public.company_settings');
  const signatory = await one(t, 'select full_name, full_name_ar, email, phone, job_title from public.app_users where id = coalesce($1::uuid, $2::uuid)', [rev.signatory_id, rev.prepared_by]);
  const quotation = await one(t, 'select reference_prefix from public.quotations where id = $1', [rev.quotation_id]);
  const revTag = `R${String(rev.revision_no).padStart(2, '0')}`;
  rev.reference = quotation?.reference_prefix ? `${quotation.reference_prefix}${revTag}` : `${rev.quotation_number}-${revTag}`;
  const tender = rev.tender_id ? await one(t, 'select number, client_reference, title from public.tenders where id = $1', [rev.tender_id]) : null;
  return { rev, lines, customer, contact, company, tender, signatory };
}

export default async function quotationRoutes(app: FastifyInstance, { db, storage, pdf }: { db: Db; storage: Storage; pdf: PdfRenderer }) {
  app.get('/quotations', async (req) => {
    const q = listQuery.extend({ status: z.enum(['open', 'won', 'lost', 'cancelled']).optional(), revision_status: z.string().optional() }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select q.*, c.name_en as customer_name, c.name_ar as customer_name_ar, o.number as opportunity_number,
             r.id as revision_id, r.revision_no, r.status as revision_status, r.total_amount, r.net_amount, r.gross_margin_pct, r.valid_until
      from public.quotations q
      join public.customers c on c.id = q.customer_id
      join public.opportunities o on o.id = q.opportunity_id
      left join lateral (select * from public.quotation_revisions r where r.quotation_id = q.id order by revision_no desc limit 1) r on true
      where ($1::text is null or q.title ilike '%' || $1 || '%' or q.number ilike '%' || $1 || '%' or c.name_en ilike '%' || $1 || '%')
        and ($2::public.quotation_status is null or q.status = $2)
        and ($3::public.revision_status is null or r.status = $3)
      order by q.created_at desc limit $4 offset $5`, [q.q || null, q.status ?? null, q.revision_status ?? null, q.limit, q.offset]));
  });

  app.post('/quotations', async (req, reply) => {
    const body = z.object({
      opportunity_id: z.uuid(),
      title: reqText(300),
      tender_id: optUuid,
      template_id: optUuid,
      currency: z.string().length(3).toUpperCase().default('SAR'),
    }).parse(req.body);
    const created = await tx(db, req, async (t) => {
      const r = await one<{ id: string }>(t, 'select public.create_quotation($1, $2, $3, $4, $5) as id',
        [body.opportunity_id, body.title, body.tender_id, body.template_id, body.currency]);
      return getOr404(t, `select q.*, (select id from public.quotation_revisions where quotation_id = q.id and revision_no = 0) as revision_id
                          from public.quotations q where q.id = $1`, [r!.id], 'Quotation');
    });
    return reply.status(201).send(created);
  });

  app.get('/quotations/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const q = await getOr404<any>(t, `
        select q.*, c.name_en as customer_name, c.name_ar as customer_name_ar, o.number as opportunity_number, o.title as opportunity_title,
               tn.number as tender_number
        from public.quotations q join public.customers c on c.id = q.customer_id
        join public.opportunities o on o.id = q.opportunity_id
        left join public.tenders tn on tn.id = q.tender_id
        where q.id = $1`, [id], 'Quotation');
      const revisions = await many(t, `select r.id, r.revision_no, r.status, r.total_amount, r.net_amount, r.gross_margin_pct,
          r.valid_until, r.created_at, r.approved_at, r.submitted_to_client_at, r.client_pdf_attachment_id, u.full_name as prepared_by_name
        from public.quotation_revisions r left join public.app_users u on u.id = r.prepared_by
        where r.quotation_id = $1 order by r.revision_no desc`, [id]);
      const contract = await one(t, 'select id, number from public.contracts where quotation_id = $1', [id]);
      const project = contract ? await one(t, 'select id, number, name from public.projects where contract_id = $1', [contract.id]) : null;
      return { ...q, revisions, contract, project };
    });
  });

  app.patch('/quotations/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({ title: reqText(300).optional(), reference_prefix: optText }).strict().parse(req.body);
    return tx(db, req, (t) => updateOrFail(t, 'quotations', id, body, 'Quotation'));
  });

  app.post('/quotations/:id/revisions', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const r = await tx(db, req, (t) => one(t, 'select public.create_quotation_revision($1) as id', [id]));
    return reply.status(201).send(r);
  });

  app.post('/quotations/:id/lost', async (req) => {
    const { id } = idParam.parse(req.params);
    const { reason } = z.object({ reason: reqText(1000) }).parse(req.body);
    return tx(db, req, async (t) => {
      await t.query('select public.mark_quotation_lost($1, $2)', [id, reason]);
      return one(t, 'select * from public.quotations where id = $1', [id]);
    });
  });

  // Revisions ---------------------------------------------------------------
  app.get('/revisions/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const doc = await loadRevisionDocument(t, id);
      const approvals = await many(t, `select a.*, u.full_name as actor_name from public.quotation_approvals a
        left join public.app_users u on u.id = a.actor_id where a.revision_id = $1 order by a.created_at`, [id]);
      const contacts = await many(t, 'select id, full_name, position from public.contacts where customer_id = $1 order by full_name', [doc.rev.customer_id]);
      return { ...doc.rev, lines: doc.lines, approvals, contacts, customer: doc.customer };
    });
  });

  app.patch('/revisions/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = revisionBody.parse(req.body);
    return tx(db, req, async (t) => {
      const data: Record<string, unknown> = { ...body };
      for (const k of ['schedule', 'payment_milestones', 'compliance'] as const) if (body[k]) data[k] = JSON.stringify(body[k]);
      if (body.vat_code) {
        const v = await one<{ rate: string }>(t, 'select rate from public.vat_codes where code = $1 and is_active', [body.vat_code]);
        if (!v) throw new HttpError(422, 'Unknown VAT code', 'invalid_value');
        data.vat_rate = v.rate;
      }
      await updateOrFail(t, 'quotation_revisions', id, data, 'Quotation revision');
      return one(t, 'select * from public.quotation_revisions where id = $1', [id]);
    });
  });

  app.post('/revisions/:id/lines', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = z.union([lineBody, z.array(lineBody).min(1).max(1000)]).parse(req.body);
    const rows = Array.isArray(body) ? body : [body];
    const result = await tx(db, req, async (t) => {
      const max = await one<{ m: number }>(t, 'select coalesce(max(sort_order), 0)::int as m from public.quotation_lines where revision_id = $1', [id]);
      let order = max?.m ?? 0;
      const inserted = [];
      for (const r of rows) {
        order += 10;
        inserted.push(await insertRow(t, 'quotation_lines', { sort_order: order, ...r, revision_id: id }));
      }
      return {
        lines: await many(t, 'select * from public.quotation_lines where revision_id = $1 order by sort_order, created_at', [id]),
        revision: await one(t, 'select * from public.quotation_revisions where id = $1', [id]),
        inserted: inserted.length,
      };
    });
    return reply.status(201).send(result);
  });

  app.patch('/lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = lineBody.partial().parse(req.body);
    return tx(db, req, async (t) => {
      const line = await updateOrFail<any>(t, 'quotation_lines', id, body, 'Line');
      return {
        line: await one(t, 'select * from public.quotation_lines where id = $1', [id]),
        revision: await one(t, 'select * from public.quotation_revisions where id = $1', [line.revision_id]),
      };
    });
  });

  app.delete('/lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const r = await t.query('delete from public.quotation_lines where id = $1 returning revision_id', [id]);
      if (!r.rowCount) throw notFound('Line');
      return { revision: await one(t, 'select * from public.quotation_revisions where id = $1', [r.rows[0].revision_id]) };
    });
  });

  app.post('/revisions/:id/apply-boq-template', async (req) => {
    const { id } = idParam.parse(req.params);
    const { template_id } = z.object({ template_id: z.uuid() }).parse(req.body);
    return tx(db, req, async (t) => {
      const r = await one<{ n: number }>(t, 'select public.apply_boq_template($1, $2) as n', [id, template_id]);
      return { inserted: r?.n ?? 0, revision: await one(t, 'select * from public.quotation_revisions where id = $1', [id]) };
    });
  });

  app.post('/revisions/:id/transition', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({
      action: z.enum(Object.keys(TRANSITIONS) as [keyof typeof TRANSITIONS, ...(keyof typeof TRANSITIONS)[]]),
      comment: z.string().trim().max(2000).optional(),
    }).parse(req.body);
    const tr = TRANSITIONS[body.action];
    if (body.action === 'reject' && !body.comment) throw new HttpError(422, 'A comment is required when rejecting a quotation', 'rule_violation');
    return tx(db, req, async (t) => {
      const updated = await one(t, `update public.quotation_revisions set status = $2, workflow_comment = $3
                                    where id = $1 and status = $4 returning id`, [id, tr.to, body.comment ?? null, tr.from]);
      if (!updated) {
        const cur = await one<{ status: string }>(t, 'select status from public.quotation_revisions where id = $1', [id]);
        if (!cur) throw notFound('Quotation revision');
        throw new HttpError(409, `This revision is ${cur.status.replace('_', ' ')}; it cannot be ${body.action.replace(/_/g, ' ')}`, 'conflict');
      }
      if (body.action === 'mark_submitted') {
        // Archive the exact PDF sent to the client alongside the revision.
        const doc = await loadRevisionDocument(t, id);
        const html = renderQuotationHtml(doc, { language: 'bilingual', draft: false });
        const file = await pdf.render(html);
        const name = `${doc.rev.reference.replace(/[^A-Za-z0-9._-]+/g, '-')}.pdf`;
        const key = newStorageKey('quotation_revision', id, name);
        await storage.put(key, file, 'application/pdf');
        const att = await insertRow<any>(t, 'attachments', {
          entity_type: 'quotation_revision', entity_id: id, file_name: name, mime_type: 'application/pdf',
          size_bytes: file.length, sha256: sha256(file), storage_path: key, category: 'client_quotation',
          is_system_generated: true, uploaded_by: req.user.id,
        });
        await t.query('update public.quotation_revisions set client_pdf_attachment_id = $2 where id = $1', [id, att.id]);
      }
      return one(t, 'select * from public.quotation_revisions where id = $1', [id]);
    });
  });

  app.post('/revisions/:id/award', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({
      project_name: z.string().trim().max(300).optional(),
      project_manager_id: z.uuid(),
      start_date: z.iso.date(),
      target_completion_date: z.iso.date(),
      signed_date: optDate,
      retention_pct: decimal.optional(),
      advance_payment_pct: decimal.optional(),
    }).parse(req.body);
    if (body.target_completion_date < body.start_date) throw new HttpError(422, 'Target completion must be on or after the start date', 'rule_violation');
    return tx(db, req, async (t) => {
      const r = await one<{ result: { contract_id: string; project_id: string } }>(t,
        'select public.award_quotation($1, $2, $3, $4, $5, $6, $7, $8) as result',
        [id, body.project_name ?? null, body.project_manager_id, body.start_date, body.target_completion_date,
         body.signed_date, body.retention_pct ?? '0', body.advance_payment_pct ?? '0']);
      const contract = await one(t, 'select * from public.contracts where id = $1', [r!.result.contract_id]);
      const project = await one(t, 'select * from public.projects where id = $1', [r!.result.project_id]);
      return { contract, project };
    });
  });

  app.get('/revisions/:id/pdf', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const { lang } = z.object({ lang: z.enum(['bilingual', 'en', 'ar']).default('bilingual') }).parse(req.query);
    const { html, name } = await tx(db, req, async (t) => {
      const doc = await loadRevisionDocument(t, id);
      const draft = !['approved', 'submitted', 'awarded'].includes(doc.rev.status);
      return {
        html: renderQuotationHtml(doc, { language: lang as PdfLanguage, draft }),
        name: `${doc.rev.reference.replace(/[^A-Za-z0-9._-]+/g, '-')}${draft ? '-DRAFT' : ''}.pdf`,
      };
    });
    const file = await pdf.render(html);
    return reply.header('Content-Type', 'application/pdf')
      .header('Content-Disposition', `inline; filename="${name}"`)
      .header('Cache-Control', 'no-store')
      .send(file);
  });

  // Contracts and projects created by award (read-only in Phase 1) ---------------
  app.get('/contracts', async (req) => tx(db, req, (t) => many(t, `
    select ct.id, ct.number, ct.title, ct.currency, ct.original_value, ct.vat_rate, ct.status, ct.signed_date, ct.created_at,
           c.name_en as customer_name, q.number as quotation_number, p.id as project_id, p.number as project_number
    from public.contracts ct join public.customers c on c.id = ct.customer_id
    join public.quotations q on q.id = ct.quotation_id left join public.projects p on p.contract_id = ct.id
    order by ct.created_at desc`)));

  app.get('/projects', async (req) => tx(db, req, (t) => many(t, `
    select p.*, c.name_en as customer_name, u.full_name as project_manager_name, ct.number as contract_number, ct.original_value
    from public.projects p join public.customers c on c.id = p.customer_id
    join public.contracts ct on ct.id = p.contract_id left join public.app_users u on u.id = p.project_manager_id
    order by p.created_at desc`)));
}
