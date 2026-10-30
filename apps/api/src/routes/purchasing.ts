import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { insertRow, many, one, type Db, type Tx } from '../db.js';
import { HttpError, notFound } from '../errors.js';
import { approvalInfo } from './approvals.js';
import { decimal, getOr404, idParam, listQuery, optDate, optText, optUuid, reqText, tx, updateOrFail } from './util.js';

// Supplier quotations and comparison, goods received notes, supplier invoices (3-way match) and supplier payments.

const quoteBody = z.object({
  quote_ref: optText,
  quote_date: optDate,
  valid_until: optDate,
  delivery_days: z.coerce.number().int().min(0).max(3650).nullish(),
  delivery_terms: optText,
  payment_terms: optText,
  warranty: optText,
  technical_compliance: z.enum(['compliant', 'partial', 'non_compliant']).optional(),
  commercial_notes: optText,
}).strict();

const quoteLine = z.object({
  request_line_id: z.uuid(),
  unit_price: decimal,
  quantity: decimal.optional(),
  vat_code: z.string().max(10).optional(),
  notes: optText,
}).strict();

const billBody = z.object({
  supplier_invoice_number: reqText(100).optional(),
  invoice_date: optDate,
  due_date: optDate,
  retention_pct: decimal.optional(),
  advance_recovery: decimal.optional(),
  cost_category: z.string().max(30).nullish(),
  project_id: optUuid,
  notes: optText,
}).strict();

const billLine = z.object({
  po_line_id: optUuid,
  description: reqText(2000),
  unit: z.string().trim().min(1).max(20).optional(),
  quantity: decimal,
  unit_price: decimal,
  vat_code: z.string().max(10).optional(),
  cost_category: z.string().max(30).nullish(),
}).strict();

async function loadQuoteRequest(t: Tx, requestId: string) {
  const request = await getOr404<any>(t, 'select id, number, title, status, cost_category, project_id from public.purchase_requests where id = $1', [requestId], 'Purchase request');
  const items = await many(t, 'select id, description, unit, quantity, estimated_unit_cost from public.purchase_request_lines where request_id = $1 order by sort_order, created_at', [requestId]);
  const quotes = await many(t, `
    select q.*, s.name_en as supplier_name, s.name_ar as supplier_name_ar, s.vat_number as supplier_vat_number
    from public.supplier_quotes q join public.suppliers s on s.id = q.supplier_id where q.request_id = $1 order by q.total_amount, q.quote_date`, [requestId]);
  const lines = await many(t, `select l.* from public.supplier_quote_lines l join public.supplier_quotes q on q.id = l.quote_id where q.request_id = $1`, [requestId]);
  // Comparison: per item, each supplier's price; lowest price per item and lowest compliant total are flagged.
  const priced = quotes.filter((q) => lines.some((l) => l.quote_id === q.id));
  const compliant = priced.filter((q) => q.technical_compliance !== 'non_compliant');
  const lowestTotal = compliant.length ? compliant.reduce((a, b) => (Number(b.total_amount) < Number(a.total_amount) ? b : a)).id : null;
  const fastest = priced.filter((q) => q.delivery_days != null).sort((a, b) => a.delivery_days - b.delivery_days)[0]?.id ?? null;
  const comparison = items.map((it) => {
    const prices = quotes.map((q) => {
      const l = lines.find((x) => x.quote_id === q.id && x.request_line_id === it.id);
      return { quote_id: q.id, unit_price: l?.unit_price ?? null, net_amount: l?.net_amount ?? null, vat_code: l?.vat_code ?? null };
    });
    const offered = prices.filter((p) => p.unit_price != null);
    const lowest = offered.length ? offered.reduce((a, b) => (Number(b.unit_price) < Number(a.unit_price) ? b : a)).quote_id : null;
    return { ...it, prices, lowest_quote_id: lowest };
  });
  return { request, items, quotes: quotes.map((q) => ({ ...q, lines: lines.filter((l) => l.quote_id === q.id),
    lowest_total: q.id === lowestTotal, fastest_delivery: q.id === fastest })), comparison, lowest_quote_id: lowestTotal };
}

async function loadBill(t: Tx, id: string) {
  const bill = await getOr404<any>(t, `
    select b.*, s.name_en as supplier_name, s.name_ar as supplier_name_ar, s.vat_number as supplier_vat_number, o.number as po_number, o.root_id as po_root_id,
           p.number as project_number, p.name as project_name, u.full_name as posted_by_name
    from public.supplier_invoices b join public.suppliers s on s.id = b.supplier_id left join public.purchase_orders o on o.id = b.po_id
    left join public.projects p on p.id = b.project_id left join public.app_users u on u.id = b.posted_by where b.id = $1`, [id], 'Supplier invoice');
  bill.lines = await many(t, 'select * from public.supplier_invoice_lines where invoice_id = $1 order by sort_order, created_at', [id]);
  bill.match = bill.status === 'draft' ? (await one<any>(t, 'select public.match_supplier_invoice($1) as m', [id]))?.m : bill.match_details;
  bill.payments = await many(t, `select id, number, kind, payment_date, amount, method, reference, voided_at, void_reason from public.supplier_payments
                                  where invoice_id = $1 order by created_at`, [id]);
  bill.advance_open = (await one<any>(t, 'select public.supplier_advance_open($1, $2) as v', [bill.supplier_id, bill.po_root_id]))?.v ?? '0';
  bill.approvals = await approvalInfo(t, 'supplier_invoice', id, bill.subtotal);
  if (bill.po_id) {
    bill.po_lines = await many(t, `
      select l.id, l.description, l.unit, l.quantity, round(l.net_amount / l.quantity, 4) as unit_cost, l.vat_code, l.cost_category,
             public.po_line_received(l.line_ref) as received_qty, public.po_line_invoiced(l.line_ref) as invoiced_qty
      from public.purchase_order_lines l where l.order_id = $1 order by l.sort_order`, [bill.po_id]);
  }
  return bill;
}

export default async function purchasingRoutes(app: FastifyInstance, { db }: { db: Db }) {
  // Supplier quotations ----------------------------------------------------------
  app.get('/purchase-requests/:id/quotes', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, (t) => loadQuoteRequest(t, id));
  });

  // Record a supplier's quotation; lines default to every requested item at the quoted prices given.
  app.post('/purchase-requests/:id/quotes', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = quoteBody.extend({ supplier_id: z.uuid(), lines: z.array(quoteLine).max(500).optional() }).parse(req.body);
    const r = await tx(db, req, async (t) => {
      const { lines, ...head } = body;
      const q = await insertRow<any>(t, 'supplier_quotes', { ...head, request_id: id });
      for (const l of lines ?? []) {
        const item = await one<any>(t, 'select quantity from public.purchase_request_lines where id = $1 and request_id = $2', [l.request_line_id, id]);
        if (!item) throw new HttpError(422, 'The item is not on this purchase request', 'rule_violation');
        await insertRow(t, 'supplier_quote_lines', { ...l, quantity: l.quantity ?? item.quantity, quote_id: q.id });
      }
      return loadQuoteRequest(t, id);
    });
    return reply.status(201).send(r);
  });

  app.patch('/supplier-quotes/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = quoteBody.parse(req.body);
    return tx(db, req, async (t) => { const q = await updateOrFail<any>(t, 'supplier_quotes', id, body, 'Supplier quotation'); return loadQuoteRequest(t, q.request_id); });
  });

  // Replace the quotation's prices (one entry per item; omit an item the supplier did not quote).
  app.put('/supplier-quotes/:id/lines', async (req) => {
    const { id } = idParam.parse(req.params);
    const lines = z.array(quoteLine).max(500).parse(req.body);
    return tx(db, req, async (t) => {
      const q = await getOr404<any>(t, 'select request_id from public.supplier_quotes where id = $1', [id], 'Supplier quotation');
      await t.query('delete from public.supplier_quote_lines where quote_id = $1', [id]);
      for (const l of lines) {
        const item = await one<any>(t, 'select quantity from public.purchase_request_lines where id = $1 and request_id = $2', [l.request_line_id, q.request_id]);
        if (!item) throw new HttpError(422, 'The item is not on this purchase request', 'rule_violation');
        await insertRow(t, 'supplier_quote_lines', { ...l, quantity: l.quantity ?? item.quantity, quote_id: id });
      }
      return loadQuoteRequest(t, q.request_id);
    });
  });

  app.post('/supplier-quotes/:id/select', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const { reason } = z.object({ reason: z.string().trim().max(2000).optional() }).parse(req.body ?? {});
    const r = await tx(db, req, async (t) => (await one<{ id: string }>(t, 'select public.select_supplier_quote($1, $2) as id', [id, reason ?? null]))!.id);
    return reply.status(201).send({ purchase_order_id: r });
  });

  // Goods received ------------------------------------------------------------------
  app.post('/purchase-orders/:id/receipts', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({
      receipt_date: optDate,
      delivery_note_ref: optText,
      notes: optText,
      lines: z.array(z.object({ po_line_id: z.uuid(), quantity: decimal, notes: optText }).strict()).min(1).max(500),
    }).strict().parse(req.body);
    const r = await tx(db, req, async (t) => {
      const g = await one<{ id: string }>(t, 'select public.receive_goods($1, $2, $3, $4, $5::jsonb) as id',
        [id, body.receipt_date ?? null, body.delivery_note_ref ?? null, body.notes ?? null, JSON.stringify(body.lines)]);
      return one(t, 'select * from public.goods_receipts where id = $1', [g!.id]);
    });
    return reply.status(201).send(r);
  });

  app.get('/goods-receipts', async (req) => {
    const q = listQuery.extend({ po_id: z.uuid().optional(), project_id: z.uuid().optional() }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select g.*, o.number as po_number, s.name_en as supplier_name, p.number as project_number,
             (select sum(amount) from public.goods_receipt_lines where receipt_id = g.id) as amount
      from public.goods_receipts g join public.purchase_orders o on o.id = g.po_id join public.suppliers s on s.id = o.supplier_id
      left join public.projects p on p.id = o.project_id
      where ($1::uuid is null or g.po_id = $1) and ($2::uuid is null or o.project_id = $2)
        and ($3::text is null or g.number ilike '%' || $3 || '%' or o.number ilike '%' || $3 || '%' or s.name_en ilike '%' || $3 || '%')
      order by g.created_at desc limit $4 offset $5`, [q.po_id ?? null, q.project_id ?? null, q.q || null, q.limit, q.offset]));
  });

  app.post('/goods-receipts/:id/cancel', async (req) => {
    const { id } = idParam.parse(req.params);
    const { reason } = z.object({ reason: z.string().trim().max(1000) }).parse(req.body ?? {});
    return tx(db, req, async (t) => {
      await t.query('select public.cancel_goods_receipt($1, $2)', [id, reason]);
      return one(t, 'select * from public.goods_receipts where id = $1', [id]);
    });
  });

  // Supplier invoices ----------------------------------------------------------------
  app.get('/supplier-invoices', async (req) => {
    const q = listQuery.extend({
      status: z.enum(['draft', 'posted', 'cancelled']).optional(), supplier_id: z.uuid().optional(), project_id: z.uuid().optional(),
      po_id: z.uuid().optional(), unpaid: z.coerce.boolean().optional(),
    }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select b.id, b.number, b.supplier_invoice_number, b.invoice_date, b.due_date, b.status, b.match_status, b.subtotal, b.vat_total, b.total_amount,
             b.amount_payable, b.amount_paid, b.retention_amount, b.retention_released, s.name_en as supplier_name, o.number as po_number, p.number as project_number
      from public.supplier_invoices b join public.suppliers s on s.id = b.supplier_id left join public.purchase_orders o on o.id = b.po_id
      left join public.projects p on p.id = b.project_id
      where ($1::text is null or b.status = $1) and ($2::uuid is null or b.supplier_id = $2) and ($3::uuid is null or b.project_id = $3)
        and ($4::uuid is null or b.po_id = $4) and (not $5 or (b.status = 'posted' and b.amount_payable > b.amount_paid))
        and ($6::text is null or b.number ilike '%' || $6 || '%' or b.supplier_invoice_number ilike '%' || $6 || '%' or s.name_en ilike '%' || $6 || '%')
      order by b.created_at desc limit $7 offset $8`,
      [q.status ?? null, q.supplier_id ?? null, q.project_id ?? null, q.po_id ?? null, q.unpaid ?? false, q.q || null, q.limit, q.offset]));
  });

  // Enter a supplier invoice. With a PO and no lines given, the lines are what was received but not yet invoiced, at PO prices.
  app.post('/supplier-invoices', async (req, reply) => {
    const body = billBody.extend({
      supplier_invoice_number: reqText(100), invoice_date: z.iso.date(), supplier_id: z.uuid().optional(), po_id: z.uuid().optional(),
      lines: z.array(billLine).max(500).optional(),
    }).parse(req.body);
    if (!body.supplier_id && !body.po_id) throw new HttpError(422, 'Choose the supplier or the purchase order', 'rule_violation');
    const r = await tx(db, req, async (t) => {
      const { lines, ...head } = body;
      let supplier = head.supplier_id;
      if (head.po_id) supplier = (await getOr404<any>(t, 'select supplier_id from public.purchase_orders where id = $1', [head.po_id], 'Purchase order')).supplier_id;
      const b = await insertRow<any>(t, 'supplier_invoices', { ...head, supplier_id: supplier });
      let order = 0;
      if (lines?.length) {
        for (const l of lines) { order += 10; await insertRow(t, 'supplier_invoice_lines', { ...l, invoice_id: b.id, sort_order: order }); }
      } else if (head.po_id) {
        const open = await many<any>(t, `
          select l.id, l.description, l.unit, l.vat_code, round(l.net_amount / l.quantity, 4) as unit_cost,
                 public.po_line_received(l.line_ref) - public.po_line_invoiced(l.line_ref) as qty
          from public.purchase_order_lines l where l.order_id = $1 order by l.sort_order`, [head.po_id]);
        for (const l of open.filter((x) => Number(x.qty) > 0)) {
          order += 10;
          await insertRow(t, 'supplier_invoice_lines', { invoice_id: b.id, sort_order: order, po_line_id: l.id, description: l.description,
            unit: l.unit, quantity: l.qty, unit_price: l.unit_cost, vat_code: l.vat_code });
        }
      }
      return loadBill(t, b.id);
    });
    return reply.status(201).send(r);
  });

  app.get('/supplier-invoices/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, (t) => loadBill(t, id));
  });

  app.patch('/supplier-invoices/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = billBody.parse(req.body);
    return tx(db, req, async (t) => { await updateOrFail(t, 'supplier_invoices', id, body, 'Supplier invoice'); return loadBill(t, id); });
  });

  app.post('/supplier-invoices/:id/lines', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = billLine.parse(req.body);
    const r = await tx(db, req, async (t) => {
      const max = await one<{ m: number }>(t, 'select coalesce(max(sort_order), 0)::int as m from public.supplier_invoice_lines where invoice_id = $1', [id]);
      await insertRow(t, 'supplier_invoice_lines', { ...body, invoice_id: id, sort_order: (max?.m ?? 0) + 10 });
      return loadBill(t, id);
    });
    return reply.status(201).send(r);
  });

  app.patch('/supplier-invoice-lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = billLine.partial().parse(req.body);
    return tx(db, req, async (t) => { const l = await updateOrFail<any>(t, 'supplier_invoice_lines', id, body, 'Line'); return loadBill(t, l.invoice_id); });
  });

  app.delete('/supplier-invoice-lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const r = await t.query('delete from public.supplier_invoice_lines where id = $1 returning invoice_id', [id]);
      if (!r.rowCount) throw notFound('Line');
      return loadBill(t, r.rows[0].invoice_id);
    });
  });

  app.post('/supplier-invoices/:id/post', async (req) => {
    const { id } = idParam.parse(req.params);
    const { override_comment } = z.object({ override_comment: z.string().trim().max(2000).optional() }).parse(req.body ?? {});
    return tx(db, req, async (t) => { await t.query('select public.post_supplier_invoice($1, $2)', [id, override_comment ?? null]); return loadBill(t, id); });
  });

  app.post('/supplier-invoices/:id/cancel', async (req) => {
    const { id } = idParam.parse(req.params);
    const { reason } = z.object({ reason: z.string().trim().max(1000) }).parse(req.body ?? {});
    return tx(db, req, async (t) => { await t.query('select public.cancel_supplier_invoice($1, $2)', [id, reason]); return loadBill(t, id); });
  });

  // Supplier payments ----------------------------------------------------------------
  app.get('/supplier-payments', async (req) => {
    const q = listQuery.extend({ supplier_id: z.uuid().optional() }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select p.*, s.name_en as supplier_name, b.number as invoice_number, b.supplier_invoice_number, o.number as po_number
      from public.supplier_payments p join public.suppliers s on s.id = p.supplier_id left join public.supplier_invoices b on b.id = p.invoice_id
      left join public.purchase_orders o on o.id = p.po_id
      where ($1::uuid is null or p.supplier_id = $1) and ($2::text is null or p.number ilike '%' || $2 || '%' or s.name_en ilike '%' || $2 || '%')
      order by p.created_at desc limit $3 offset $4`, [q.supplier_id ?? null, q.q || null, q.limit, q.offset]));
  });

  app.post('/supplier-payments', async (req, reply) => {
    const body = z.object({
      kind: z.enum(['invoice', 'advance', 'retention']).default('invoice'),
      invoice_id: optUuid, po_id: optUuid,
      payment_date: z.iso.date(), amount: decimal,
      method: z.enum(['bank_transfer', 'cheque', 'cash', 'card', 'other']).optional(),
      bank_account_code: z.string().max(8).nullish(), reference: optText, notes: optText,
    }).strict().parse(req.body);
    const r = await tx(db, req, async (t) => {
      const supplier = body.invoice_id
        ? (await getOr404<any>(t, 'select supplier_id from public.supplier_invoices where id = $1', [body.invoice_id], 'Supplier invoice')).supplier_id
        : body.po_id ? (await getOr404<any>(t, 'select supplier_id from public.purchase_orders where id = $1', [body.po_id], 'Purchase order')).supplier_id : null;
      if (!supplier) throw new HttpError(422, 'Choose the supplier invoice or the purchase order', 'rule_violation');
      return insertRow(t, 'supplier_payments', { ...body, supplier_id: supplier });
    });
    return reply.status(201).send(r);
  });

  app.post('/supplier-payments/:id/void', async (req) => {
    const { id } = idParam.parse(req.params);
    const { reason } = z.object({ reason: z.string().trim().min(1).max(1000) }).parse(req.body ?? {});
    return tx(db, req, (t) => updateOrFail(t, 'supplier_payments', id, { voided_at: new Date().toISOString(), void_reason: reason }, 'Payment'));
  });
}
