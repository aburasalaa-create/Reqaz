import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { insertRow, many, one, type Db, type Tx } from '../db.js';
import { HttpError, notFound } from '../errors.js';
import type { Storage } from '../storage.js';
import { newStorageKey, sha256 } from '../storage.js';
import type { PdfRenderer } from '../pdf/renderer.js';
import { renderPurchaseOrderHtml } from '../pdf/purchase-order.js';
import type { PdfLanguage } from '../pdf/quotation.js';
import { decimal, getOr404, idParam, listQuery, optDate, optText, optUuid, reqText, tx, updateOrFail } from './util.js';

const prBody = z.object({
  title: reqText(300).optional(),
  project_id: optUuid,
  needed_by: optDate,
  delivery_location: optText,
  notes: optText,
}).strict();

const prLine = z.object({
  description: reqText(2000),
  unit: z.string().trim().min(1).max(20).optional(),
  quantity: decimal,
  estimated_unit_cost: decimal.optional(),
}).strict();

const poBody = z.object({
  supplier_id: z.uuid().optional(),
  project_id: optUuid,
  currency: z.string().length(3).toUpperCase().optional(),
  supplier_quote_ref: optText,
  delivery_date: optDate,
  delivery_address: optText,
  payment_terms: optText,
  terms: optText,
  notes: optText,
}).strict();

const poLine = z.object({
  item_code: optText,
  description: reqText(2000),
  unit: z.string().trim().min(1).max(20).optional(),
  quantity: decimal,
  unit_price: decimal.optional(),
  discount_amount: decimal.optional(),
  vat_code: z.string().max(10).optional(),
}).strict();

const PR_ACTIONS = { submit: 'submitted', withdraw: 'draft', approve: 'approved', reject: 'rejected', cancel: 'cancelled' } as const;
const PO_ACTIONS = { receive: 'received', close: 'closed', cancel: 'cancelled' } as const;

async function loadRequest(t: Tx, id: string) {
  const pr = await getOr404<any>(t, `
    select r.*, u.full_name as requested_by_name, d.full_name as decided_by_name, p.number as project_number, p.name as project_name,
           (select json_agg(json_build_object('id', o.id, 'number', o.number, 'status', o.status)) from public.purchase_orders o where o.purchase_request_id = r.id) as orders
    from public.purchase_requests r join public.app_users u on u.id = r.requested_by
    left join public.app_users d on d.id = r.decided_by left join public.projects p on p.id = r.project_id
    where r.id = $1`, [id], 'Purchase request');
  pr.lines = await many(t, 'select * from public.purchase_request_lines where request_id = $1 order by sort_order, created_at', [id]);
  return pr;
}

async function loadOrder(t: Tx, id: string) {
  const po = await getOr404<any>(t, `
    select o.*, coalesce(s.name_en, o.supplier_snapshot ->> 'name_en') as supplier_name, s.name_ar as supplier_name_ar, s.code as supplier_code, r.number as request_number,
           p.number as project_number, p.name as project_name, u.full_name as issued_by_name
    from public.purchase_orders o left join public.suppliers s on s.id = o.supplier_id
    left join public.purchase_requests r on r.id = o.purchase_request_id
    left join public.projects p on p.id = o.project_id left join public.app_users u on u.id = o.issued_by
    where o.id = $1`, [id], 'Purchase order');
  po.lines = await many(t, 'select * from public.purchase_order_lines where order_id = $1 order by sort_order, created_at', [id]);
  return po;
}

async function orderDocument(t: Tx, id: string) {
  const po = await loadOrder(t, id);
  const issued = po.status !== 'draft';
  const buyer = issued ? po.buyer_snapshot : await one(t, 'select * from public.company_settings');
  const supplier = issued ? po.supplier_snapshot : await one(t, 'select * from public.suppliers where id = $1', [po.supplier_id]);
  const stamp = issued && po.status !== 'cancelled'
    ? await one<{ mime_type: string; data: Buffer }>(t, `select mime_type, data from public.brand_assets where code = 'stamp'`) : null;
  return { po, lines: po.lines, buyer, supplier, stampDataUrl: stamp ? `data:${stamp.mime_type};base64,${stamp.data.toString('base64')}` : null };
}

const poFileName = (po: any) => `${(po.number ?? 'PO-DRAFT').replace(/[^A-Za-z0-9._-]+/g, '-')}.pdf`;

export default async function procurementRoutes(app: FastifyInstance, { db, storage, pdf }: { db: Db; storage: Storage; pdf: PdfRenderer }) {
  // Purchase requests ----------------------------------------------------------
  app.get('/purchase-requests', async (req) => {
    const q = listQuery.extend({ status: z.enum(['draft', 'submitted', 'approved', 'rejected', 'ordered', 'cancelled']).optional(), mine: z.coerce.boolean().optional() }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select r.id, r.number, r.title, r.status, r.needed_by, r.estimated_total, r.created_at, r.submitted_at,
             u.full_name as requested_by_name, p.number as project_number, p.name as project_name
      from public.purchase_requests r join public.app_users u on u.id = r.requested_by left join public.projects p on p.id = r.project_id
      where ($1::text is null or r.title ilike '%' || $1 || '%' or r.number ilike '%' || $1 || '%')
        and ($2::public.pr_status is null or r.status = $2) and (not $3 or r.requested_by = auth.uid())
      order by r.created_at desc limit $4 offset $5`, [q.q || null, q.status ?? null, q.mine ?? false, q.limit, q.offset]));
  });

  app.post('/purchase-requests', async (req, reply) => {
    const body = prBody.extend({ title: reqText(300), lines: z.array(prLine).max(200).optional() }).parse(req.body);
    const created = await tx(db, req, async (t) => {
      const { lines, ...head } = body;
      const pr = await insertRow<any>(t, 'purchase_requests', head);
      let order = 0;
      for (const l of lines ?? []) { order += 10; await insertRow(t, 'purchase_request_lines', { ...l, sort_order: order, request_id: pr.id }); }
      return loadRequest(t, pr.id);
    });
    return reply.status(201).send(created);
  });

  app.get('/purchase-requests/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, (t) => loadRequest(t, id));
  });

  app.patch('/purchase-requests/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = prBody.parse(req.body);
    return tx(db, req, async (t) => { await updateOrFail(t, 'purchase_requests', id, body, 'Purchase request'); return loadRequest(t, id); });
  });

  app.post('/purchase-requests/:id/lines', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = prLine.parse(req.body);
    const r = await tx(db, req, async (t) => {
      const max = await one<{ m: number }>(t, 'select coalesce(max(sort_order), 0)::int as m from public.purchase_request_lines where request_id = $1', [id]);
      await insertRow(t, 'purchase_request_lines', { ...body, sort_order: (max?.m ?? 0) + 10, request_id: id });
      return loadRequest(t, id);
    });
    return reply.status(201).send(r);
  });

  app.patch('/purchase-request-lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = prLine.partial().parse(req.body);
    return tx(db, req, async (t) => { const l = await updateOrFail<any>(t, 'purchase_request_lines', id, body, 'Line'); return loadRequest(t, l.request_id); });
  });

  app.delete('/purchase-request-lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const r = await t.query('delete from public.purchase_request_lines where id = $1 returning request_id', [id]);
      if (!r.rowCount) throw notFound('Line');
      return loadRequest(t, r.rows[0].request_id);
    });
  });

  app.post('/purchase-requests/:id/:action', async (req) => {
    const { id, action } = z.object({ id: z.uuid(), action: z.enum(Object.keys(PR_ACTIONS) as [keyof typeof PR_ACTIONS]) }).parse(req.params);
    const { comment } = z.object({ comment: z.string().trim().max(2000).optional() }).parse(req.body ?? {});
    return tx(db, req, async (t) => {
      const r = await t.query('update public.purchase_requests set status = $2, decision_comment = coalesce($3, decision_comment) where id = $1 returning id',
        [id, PR_ACTIONS[action], ['approve', 'reject'].includes(action) ? (comment ?? null) : null]);
      if (!r.rowCount) {
        const visible = await one(t, 'select 1 from public.purchase_requests where id = $1', [id]);
        throw visible ? new HttpError(403, 'You do not have permission for this action', 'forbidden') : notFound('Purchase request');
      }
      return loadRequest(t, id);
    });
  });

  app.post('/purchase-requests/:id/order', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const { supplier_id } = z.object({ supplier_id: z.uuid() }).parse(req.body);
    const po = await tx(db, req, async (t) => {
      const r = await one<{ id: string }>(t, 'select public.order_from_request($1, $2) as id', [id, supplier_id]);
      return loadOrder(t, r!.id);
    });
    return reply.status(201).send(po);
  });

  // Purchase orders --------------------------------------------------------------
  app.get('/purchase-orders', async (req) => {
    const q = listQuery.extend({ status: z.enum(['draft', 'issued', 'received', 'closed', 'cancelled']).optional(), supplier_id: z.uuid().optional() }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select o.id, o.number, o.status, o.issue_date, o.delivery_date, o.currency, o.total_amount, o.created_at,
             coalesce(s.name_en, o.supplier_snapshot ->> 'name_en') as supplier_name, s.name_ar as supplier_name_ar, r.number as request_number, p.number as project_number
      from public.purchase_orders o left join public.suppliers s on s.id = o.supplier_id
      left join public.purchase_requests r on r.id = o.purchase_request_id left join public.projects p on p.id = o.project_id
      where ($1::text is null or o.number ilike '%' || $1 || '%' or s.name_en ilike '%' || $1 || '%')
        and ($2::public.po_status is null or o.status = $2) and ($3::uuid is null or o.supplier_id = $3)
      order by coalesce(o.issued_at, o.created_at) desc limit $4 offset $5`, [q.q || null, q.status ?? null, q.supplier_id ?? null, q.limit, q.offset]));
  });

  app.post('/purchase-orders', async (req, reply) => {
    const body = poBody.extend({ supplier_id: z.uuid() }).parse(req.body);
    const po = await tx(db, req, async (t) => {
      const s = await one<any>(t, 'select payment_terms_days, currency from public.suppliers where id = $1 and is_active', [body.supplier_id]);
      if (!s) throw new HttpError(422, 'Choose an active supplier', 'rule_violation');
      const created = await insertRow<any>(t, 'purchase_orders', {
        ...body, currency: body.currency ?? s.currency,
        payment_terms: body.payment_terms ?? (s.payment_terms_days ? `${s.payment_terms_days} days from invoice` : undefined),
      });
      return loadOrder(t, created.id);
    });
    return reply.status(201).send(po);
  });

  app.get('/purchase-orders/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, (t) => loadOrder(t, id));
  });

  app.patch('/purchase-orders/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = poBody.parse(req.body);
    return tx(db, req, async (t) => {
      const cur = await getOr404<any>(t, 'select status from public.purchase_orders where id = $1', [id], 'Purchase order');
      if (cur.status !== 'draft') throw new HttpError(403, 'An issued purchase order cannot be changed; cancel it and issue a new one', 'forbidden');
      await updateOrFail(t, 'purchase_orders', id, body, 'Purchase order');
      return loadOrder(t, id);
    });
  });

  app.post('/purchase-orders/:id/lines', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = z.union([poLine, z.array(poLine).min(1).max(500)]).parse(req.body);
    const r = await tx(db, req, async (t) => {
      const max = await one<{ m: number }>(t, 'select coalesce(max(sort_order), 0)::int as m from public.purchase_order_lines where order_id = $1', [id]);
      let order = max?.m ?? 0;
      for (const l of Array.isArray(body) ? body : [body]) { order += 10; await insertRow(t, 'purchase_order_lines', { ...l, sort_order: order, order_id: id }); }
      return loadOrder(t, id);
    });
    return reply.status(201).send(r);
  });

  app.patch('/purchase-order-lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = poLine.partial().parse(req.body);
    return tx(db, req, async (t) => { const l = await updateOrFail<any>(t, 'purchase_order_lines', id, body, 'Line'); return loadOrder(t, l.order_id); });
  });

  app.delete('/purchase-order-lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const r = await t.query('delete from public.purchase_order_lines where id = $1 returning order_id', [id]);
      if (!r.rowCount) throw notFound('Line');
      return loadOrder(t, r.rows[0].order_id);
    });
  });

  // Issue: number, frozen parties and archived PDF commit together.
  app.post('/purchase-orders/:id/issue', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      await t.query('select public.issue_purchase_order($1)', [id]);
      const doc = await orderDocument(t, id);
      const file = await pdf.render(renderPurchaseOrderHtml(doc, { language: 'bilingual' }));
      const name = poFileName(doc.po);
      const key = newStorageKey('purchase_order', id, name);
      await storage.put(key, file, 'application/pdf');
      const att = await insertRow<any>(t, 'attachments', {
        entity_type: 'purchase_order', entity_id: id, file_name: name, mime_type: 'application/pdf', size_bytes: file.length,
        sha256: sha256(file), storage_path: key, category: 'issued_purchase_order', is_system_generated: true, uploaded_by: req.user.id,
      });
      await t.query('update public.purchase_orders set pdf_attachment_id = $2 where id = $1', [id, att.id]);
      return loadOrder(t, id);
    });
  });

  app.post('/purchase-orders/:id/:action', async (req) => {
    const { id, action } = z.object({ id: z.uuid(), action: z.enum(Object.keys(PO_ACTIONS) as [keyof typeof PO_ACTIONS]) }).parse(req.params);
    const { reason } = z.object({ reason: z.string().trim().max(1000).optional() }).parse(req.body ?? {});
    return tx(db, req, async (t) => {
      await updateOrFail(t, 'purchase_orders', id, { status: PO_ACTIONS[action], cancel_reason: action === 'cancel' ? (reason ?? '') : undefined }, 'Purchase order');
      return loadOrder(t, id);
    });
  });

  app.get('/purchase-orders/:id/pdf', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const { lang } = z.object({ lang: z.enum(['bilingual', 'en', 'ar']).default('bilingual') }).parse(req.query);
    const { html, name } = await tx(db, req, async (t) => {
      const doc = await orderDocument(t, id);
      return { html: renderPurchaseOrderHtml(doc, { language: lang as PdfLanguage }), name: poFileName(doc.po) };
    });
    const file = await pdf.render(html);
    return reply.header('Content-Type', 'application/pdf').header('Content-Disposition', `inline; filename="${name}"`)
      .header('Cache-Control', 'no-store').send(file);
  });
}
