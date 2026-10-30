import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { insertRow, many, one, type Db, type Tx } from '../db.js';
import { HttpError, notFound } from '../errors.js';
import { approvalInfo } from './approvals.js';
import { decimal, getOr404, idParam, listQuery, optDate, optText, optUuid, reqText, tx, updateOrFail } from './util.js';

// Purchase orders received from customers: register, review against the quotation, accept, convert to a project, bill.

const STATUSES = ['received', 'under_review', 'clarification_required', 'accepted', 'rejected', 'active', 'completed', 'closed', 'cancelled', 'superseded'] as const;

const poBody = z.object({
  customer_po_number: reqText(100).optional(),
  contact_id: optUuid,
  po_date: z.iso.date().optional(),
  received_date: z.iso.date().optional(),
  quotation_id: optUuid,
  quotation_revision_id: optUuid,
  currency: z.string().length(3).toUpperCase().optional(),
  amount: decimal.optional(),
  vat_rate: decimal.optional(),
  vat_amount: decimal.optional(),
  payment_terms: optText,
  delivery_date: optDate,
  completion_date: optDate,
  scope_notes: optText,
  responsible_user_id: optUuid,
}).strict();

const lineBody = z.object({
  quotation_line_id: optUuid,
  item_code: optText,
  description: reqText(2000),
  unit: z.string().trim().min(1).max(20).optional(),
  quantity: decimal,
  unit_price: decimal,
}).strict();

const ACTIONS = {
  review: 'under_review', clarify: 'clarification_required', resume: 'under_review', accept: 'accepted', reject: 'rejected',
  complete: 'completed', close: 'closed', cancel: 'cancelled',
} as const;

const n = (v: unknown) => Number(v ?? 0);
const norm = (s: string | null | undefined) => (s ?? '').toLowerCase().replace(/\s+/g, ' ').trim();

/** Compare the customer's order with the quotation it answers: scope, quantities, prices, VAT, payment terms and dates. */
async function comparison(t: Tx, po: any, lines: any[]) {
  if (!po.quotation_revision_id) return null;
  const rev = await one<any>(t, `
    select r.id, r.revision_no, r.status, r.net_amount, r.vat_rate, r.vat_amount, r.total_amount, r.payment_terms_en, r.completion_period_en,
           r.valid_until, r.payment_milestones, q.number as quotation_number, q.currency
    from public.quotation_revisions r join public.quotations q on q.id = r.quotation_id where r.id = $1`, [po.quotation_revision_id]);
  if (!rev) return null;
  const qLines = await many<any>(t, `select id, item_code, description_en, unit, quantity, sell_rate, sell_total from public.quotation_lines
                                     where revision_id = $1 and quantity > 0 order by sort_order, created_at`, [rev.id]);
  const used = new Set<string>();
  const rows: any[] = [];
  for (const l of lines) {
    const q = qLines.find((x) => x.id === l.quotation_line_id && !used.has(x.id))
      ?? qLines.find((x) => !used.has(x.id) && ((l.item_code && x.item_code === l.item_code) || norm(x.description_en) === norm(l.description)));
    if (q) used.add(q.id);
    const issues: string[] = [];
    if (!q) issues.push('not_in_quotation');
    else {
      if (n(q.quantity) !== n(l.quantity)) issues.push('quantity');
      if (n(q.sell_rate) !== n(l.unit_price)) issues.push('price');
      if (norm(q.unit) !== norm(l.unit)) issues.push('unit');
    }
    rows.push({
      description: l.description, po_line_id: l.id, quotation_line_id: q?.id ?? null,
      quoted_qty: q?.quantity ?? null, po_qty: l.quantity, quoted_unit: q?.unit ?? null, po_unit: l.unit,
      quoted_rate: q?.sell_rate ?? null, po_rate: l.unit_price, quoted_amount: q?.sell_total ?? null, po_amount: l.amount,
      difference: (n(l.amount) - n(q?.sell_total)).toFixed(2), issues,
    });
  }
  for (const q of qLines.filter((x) => !used.has(x.id))) {
    rows.push({ description: q.description_en, po_line_id: null, quotation_line_id: q.id, quoted_qty: q.quantity, po_qty: null, quoted_unit: q.unit,
      po_unit: null, quoted_rate: q.sell_rate, po_rate: null, quoted_amount: q.sell_total, po_amount: null,
      difference: (-n(q.sell_total)).toFixed(2), issues: ['missing_from_order'] });
  }
  const expectedVat = (n(po.amount) * n(po.vat_rate) / 100).toFixed(2);
  const summary = [
    { field: 'amount', quoted: rev.net_amount, ordered: po.amount, match: n(rev.net_amount) === n(po.amount) },
    { field: 'vat_rate', quoted: rev.vat_rate, ordered: po.vat_rate, match: n(rev.vat_rate) === n(po.vat_rate) },
    { field: 'vat_amount', quoted: expectedVat, ordered: po.vat_amount, match: n(expectedVat) === n(po.vat_amount) },
    { field: 'total', quoted: rev.total_amount, ordered: po.total_amount, match: n(rev.total_amount) === n(po.total_amount) },
    { field: 'currency', quoted: rev.currency, ordered: po.currency, match: rev.currency === po.currency },
    { field: 'payment_terms', quoted: rev.payment_terms_en, ordered: po.payment_terms, match: norm(rev.payment_terms_en) === norm(po.payment_terms) },
    { field: 'completion', quoted: rev.completion_period_en, ordered: po.completion_date, match: null },
    { field: 'quotation_valid_until', quoted: rev.valid_until, ordered: po.po_date, match: !rev.valid_until || po.po_date <= rev.valid_until },
  ];
  return {
    quotation: { id: rev.id, number: rev.quotation_number, revision_no: rev.revision_no, status: rev.status },
    summary, lines: rows,
    differences: summary.filter((s) => s.match === false).length + rows.filter((r) => r.issues.length).length,
    partial: po.po_type === 'partial' || n(po.amount) < n(rev.net_amount),
  };
}

async function loadPo(t: Tx, id: string) {
  const po = await getOr404<any>(t, `
    select o.*, c.name_en as customer_name, c.name_ar as customer_name_ar, k.full_name as contact_name, q.number as quotation_number,
           r.revision_no, p.number as project_number, p.name as project_name, p.status as project_status, ct.number as contract_number,
           u.full_name as responsible_name, a.full_name as accepted_by_name, rv.full_name as reviewed_by_name, par.number as parent_number,
           par.customer_po_number as parent_customer_po_number
    from public.customer_pos o join public.customers c on c.id = o.customer_id
    left join public.contacts k on k.id = o.contact_id left join public.quotations q on q.id = o.quotation_id
    left join public.quotation_revisions r on r.id = o.quotation_revision_id left join public.projects p on p.id = o.project_id
    left join public.contracts ct on ct.id = o.contract_id left join public.app_users u on u.id = o.responsible_user_id
    left join public.app_users a on a.id = o.accepted_by left join public.app_users rv on rv.id = o.reviewed_by
    left join public.customer_pos par on par.id = o.parent_id
    where o.id = $1`, [id], 'Customer order');
  po.lines = await many(t, 'select * from public.customer_po_lines where po_id = $1 order by sort_order, created_at', [id]);
  po.milestones = await many(t, `
    select m.*, (select json_build_object('id', i.id, 'number', i.number, 'status', i.status) from public.invoices i
                  where i.milestone_id = m.id and i.status <> 'cancelled' limit 1) as invoice
    from public.customer_po_milestones m where m.po_id = $1 order by m.sort_order, m.created_at`, [id]);
  po.invoices = await many(t, `
    select i.id, i.number, i.kind, i.status, i.billing_type, i.claim_no, i.issue_date, i.taxable_amount, i.advance_recovery, i.vat_total,
           i.total_amount, i.retention_amount, i.retention_received, i.amount_payable, i.amount_paid, i.title
    from public.invoices i where i.customer_po_id = $1
       or i.original_invoice_id in (select id from public.invoices where customer_po_id = $1)
    order by i.created_at`, [id]);
  const billed = await one<any>(t, 'select public.customer_po_billed($1) as v', [id]);
  const issued = po.invoices.filter((i: any) => i.status === 'issued' && i.kind !== 'proforma');
  po.billing = {
    billed: billed?.v ?? '0',
    remaining: (n(po.amount) - n(billed?.v)).toFixed(2),
    advance_invoiced: issued.filter((i: any) => i.billing_type === 'advance' && i.kind === 'invoice').reduce((a: number, i: any) => a + n(i.taxable_amount), 0).toFixed(2),
    received: issued.reduce((a: number, i: any) => a + n(i.amount_paid) + n(i.retention_received), 0).toFixed(2),
    outstanding: issued.filter((i: any) => i.kind !== 'credit_note').reduce((a: number, i: any) => a + n(i.amount_payable) - n(i.amount_paid), 0).toFixed(2),
    retention_held: issued.reduce((a: number, i: any) => a + n(i.retention_amount) - n(i.retention_received), 0).toFixed(2),
  };
  po.progress = await many(t, `
    select l.id as po_line_id, coalesce(max(il.progress_pct), 0) as claimed_pct
    from public.customer_po_lines l left join public.invoice_lines il on il.customer_po_line_id = l.id
      and exists (select 1 from public.invoices i where i.id = il.invoice_id and i.status = 'issued')
    where l.po_id = $1 group by l.id`, [id]);
  if (!po.lines.length) {
    po.whole_order_claimed_pct = (await one<any>(t, `
      select coalesce(max(il.progress_pct), 0) as v from public.invoice_lines il join public.invoices i on i.id = il.invoice_id
      where i.customer_po_id = $1 and i.status = 'issued' and il.customer_po_line_id is null and il.progress_pct is not null`, [id]))?.v ?? '0';
  }
  po.related = await many(t, `select id, number, customer_po_number, po_type, status, amount from public.customer_pos
                              where (parent_id = $1 or id = $2 or (project_id is not null and project_id = $3)) and id <> $1 order by created_at`,
                          [id, po.parent_id, po.project_id]);
  po.comparison = await comparison(t, po, po.lines);
  po.approvals = await approvalInfo(t, 'customer_po', id, po.amount);
  return po;
}

export default async function customerPoRoutes(app: FastifyInstance, { db }: { db: Db }) {
  app.get('/customer-pos', async (req) => {
    const q = listQuery.extend({
      status: z.enum(STATUSES).optional(), customer_id: z.uuid().optional(), project_id: z.uuid().optional(),
      from: z.iso.date().optional(), to: z.iso.date().optional(), min_amount: decimal.optional(), max_amount: decimal.optional(),
    }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select o.id, o.number, o.customer_po_number, o.po_type, o.status, o.po_date, o.amount, o.vat_amount, o.total_amount, o.currency,
             o.completion_date, c.name_en as customer_name, c.name_ar as customer_name_ar, p.number as project_number, q.number as quotation_number,
             u.full_name as responsible_name, public.customer_po_billed(o.id) as billed
      from public.customer_pos o join public.customers c on c.id = o.customer_id left join public.projects p on p.id = o.project_id
      left join public.quotations q on q.id = o.quotation_id left join public.app_users u on u.id = o.responsible_user_id
      where ($1::text is null or o.number ilike '%' || $1 || '%' or o.customer_po_number ilike '%' || $1 || '%' or c.name_en ilike '%' || $1 || '%'
             or c.name_ar ilike '%' || $1 || '%' or p.number ilike '%' || $1 || '%')
        and ($2::text is null or o.status = $2) and ($3::uuid is null or o.customer_id = $3) and ($4::uuid is null or o.project_id = $4)
        and ($5::date is null or o.po_date >= $5) and ($6::date is null or o.po_date <= $6)
        and ($7::numeric is null or o.amount >= $7) and ($8::numeric is null or o.amount <= $8)
      order by o.created_at desc limit $9 offset $10`,
      [q.q || null, q.status ?? null, q.customer_id ?? null, q.project_id ?? null, q.from ?? null, q.to ?? null,
       q.min_amount ?? null, q.max_amount ?? null, q.limit, q.offset]));
  });

  // Register a customer order. copy_quotation_lines fills its lines from the quotation so only differences need typing.
  app.post('/customer-pos', async (req, reply) => {
    const body = poBody.extend({
      customer_po_number: reqText(100), po_date: z.iso.date(), customer_id: z.uuid().optional(),
      po_type: z.enum(['original', 'amendment', 'supplementary', 'partial']).default('original'),
      parent_id: optUuid, project_id: optUuid,
      lines: z.array(lineBody).max(500).optional(), copy_quotation_lines: z.boolean().optional(),
    }).parse(req.body);
    const r = await tx(db, req, async (t) => {
      const { lines, copy_quotation_lines, ...head } = body;
      let customer = head.customer_id;
      if (!customer && head.parent_id) customer = (await getOr404<any>(t, 'select customer_id from public.customer_pos where id = $1', [head.parent_id], 'Order')).customer_id;
      if (!customer && head.quotation_id) customer = (await getOr404<any>(t, 'select customer_id from public.quotations where id = $1', [head.quotation_id], 'Quotation')).customer_id;
      if (!customer) throw new HttpError(422, 'Choose the customer', 'rule_violation');
      if (head.po_type === 'amendment' && !head.parent_id) throw new HttpError(422, 'Choose the order this amendment changes', 'rule_violation');
      const amount = head.amount;
      const po = await insertRow<any>(t, 'customer_pos', {
        ...head, customer_id: customer,
        vat_amount: head.vat_amount ?? (amount !== undefined ? (Math.round(Number(amount) * Number(head.vat_rate ?? 15)) / 100).toFixed(2) : undefined),
      });
      let order = 0;
      for (const l of lines ?? []) { order += 10; await insertRow(t, 'customer_po_lines', { ...l, po_id: po.id, sort_order: order }); }
      if (copy_quotation_lines && !lines?.length) await t.query('select public.customer_po_copy_quotation($1)', [po.id]);
      return loadPo(t, po.id);
    });
    return reply.status(201).send(r);
  });

  app.get('/customer-pos/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, (t) => loadPo(t, id));
  });

  app.patch('/customer-pos/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = poBody.parse(req.body);
    return tx(db, req, async (t) => { await updateOrFail(t, 'customer_pos', id, body, 'Customer order'); return loadPo(t, id); });
  });

  app.post('/customer-pos/:id/copy-quotation', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => { await t.query('select public.customer_po_copy_quotation($1)', [id]); return loadPo(t, id); });
  });

  app.post('/customer-pos/:id/lines', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = lineBody.parse(req.body);
    const r = await tx(db, req, async (t) => {
      const max = await one<{ m: number }>(t, 'select coalesce(max(sort_order), 0)::int as m from public.customer_po_lines where po_id = $1', [id]);
      await insertRow(t, 'customer_po_lines', { ...body, po_id: id, sort_order: (max?.m ?? 0) + 10 });
      return loadPo(t, id);
    });
    return reply.status(201).send(r);
  });

  app.patch('/customer-po-lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = lineBody.partial().parse(req.body);
    return tx(db, req, async (t) => { const l = await updateOrFail<any>(t, 'customer_po_lines', id, body, 'Line'); return loadPo(t, l.po_id); });
  });

  app.delete('/customer-po-lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const r = await t.query('delete from public.customer_po_lines where id = $1 returning po_id', [id]);
      if (!r.rowCount) throw notFound('Line');
      return loadPo(t, r.rows[0].po_id);
    });
  });

  // Project conversion (after acceptance): creates the contract and project, or joins the existing project.
  app.post('/customer-pos/:id/convert', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({
      project_name: optText, project_manager_id: optUuid, start_date: optDate, target_completion_date: optDate,
      retention_pct: decimal.optional(), advance_payment_pct: decimal.optional(),
    }).strict().parse(req.body ?? {});
    return tx(db, req, async (t) => {
      await t.query('select public.convert_customer_po($1, $2, $3, $4, $5, $6, $7)', [id, body.project_name ?? null, body.project_manager_id ?? null,
        body.start_date ?? null, body.target_completion_date ?? null, body.retention_pct ?? '0', body.advance_payment_pct ?? '0']);
      return loadPo(t, id);
    });
  });

  // Payment milestones ------------------------------------------------------------------
  const milestoneBody = z.object({
    label: reqText(300), percent: decimal.nullish(), amount: decimal.nullish(), due_date: optDate, sort_order: z.coerce.number().int().optional(),
  }).strict();

  app.post('/customer-pos/:id/milestones', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = milestoneBody.parse(req.body);
    const r = await tx(db, req, async (t) => {
      const max = await one<{ m: number }>(t, 'select coalesce(max(sort_order), 0)::int as m from public.customer_po_milestones where po_id = $1', [id]);
      await insertRow(t, 'customer_po_milestones', { ...body, po_id: id, sort_order: body.sort_order ?? (max?.m ?? 0) + 10 });
      return loadPo(t, id);
    });
    return reply.status(201).send(r);
  });

  app.delete('/customer-po-milestones/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const r = await t.query('delete from public.customer_po_milestones where id = $1 returning po_id', [id]);
      if (!r.rowCount) throw notFound('Milestone');
      return loadPo(t, r.rows[0].po_id);
    });
  });

  // Billing --------------------------------------------------------------------------------
  app.post('/customer-pos/:id/invoices', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = z.discriminatedUnion('type', [
      z.object({ type: z.literal('advance'), percent: decimal.optional(), amount: decimal.optional() }).strict(),
      z.object({ type: z.literal('progress'), lines: z.array(z.object({ po_line_id: z.uuid().nullable(), cumulative_pct: decimal }).strict()).min(1).max(500) }).strict(),
      z.object({ type: z.literal('milestone'), milestone_id: z.uuid() }).strict(),
    ]).parse(req.body);
    const invoiceId = await tx(db, req, async (t) => {
      if (body.type === 'advance') {
        if (!body.percent && !body.amount) throw new HttpError(422, 'Enter the advance percentage or amount', 'rule_violation');
        return (await one<any>(t, 'select public.create_advance_invoice($1, $2, $3) as id', [id, body.percent ?? null, body.amount ?? null]))!.id;
      }
      if (body.type === 'progress') return (await one<any>(t, 'select public.create_progress_invoice($1, $2::jsonb) as id', [id, JSON.stringify(body.lines)]))!.id;
      const m = await getOr404<any>(t, 'select po_id from public.customer_po_milestones where id = $1', [body.milestone_id], 'Milestone');
      if (m.po_id !== id) throw new HttpError(422, 'The milestone is not on this order', 'rule_violation');
      return (await one<any>(t, 'select public.create_milestone_invoice($1) as id', [body.milestone_id]))!.id;
    });
    return reply.status(201).send({ invoice_id: invoiceId });
  });

  app.post('/customer-pos/:id/:action', async (req) => {
    const { id, action } = z.object({ id: z.uuid(), action: z.enum(Object.keys(ACTIONS) as [keyof typeof ACTIONS]) }).parse(req.params);
    const { note } = z.object({ note: z.string().trim().max(2000).optional() }).parse(req.body ?? {});
    return tx(db, req, async (t) => {
      await updateOrFail(t, 'customer_pos', id, { status: ACTIONS[action], status_note: note ?? undefined }, 'Customer order');
      return loadPo(t, id);
    });
  });
}
