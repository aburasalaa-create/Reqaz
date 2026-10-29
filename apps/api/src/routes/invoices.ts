import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import QRCode from 'qrcode';
import { insertRow, many, one, type Db, type Tx } from '../db.js';
import { HttpError, notFound } from '../errors.js';
import type { Storage } from '../storage.js';
import { newStorageKey, sha256 } from '../storage.js';
import type { PdfRenderer } from '../pdf/renderer.js';
import { renderInvoiceHtml, invoiceTitle } from '../pdf/invoice.js';
import type { PdfLanguage } from '../pdf/quotation.js';
import { decimal, getOr404, idParam, listQuery, optDate, optText, optUuid, reqText, tx, updateOrFail } from './util.js';

const headerBody = z.object({
  zatca_type: z.enum(['standard', 'simplified']).optional(),
  contract_id: optUuid,
  project_id: optUuid,
  note_reason: optText,
  currency: z.string().length(3).toUpperCase().optional(),
  supply_date: optDate,
  supply_end_date: optDate,
  due_date: optDate,
  customer_reference: optText,
  title: optText,
  notes_en: optText, notes_ar: optText,
  payment_terms_en: optText, payment_terms_ar: optText,
  retention_pct: decimal.optional(),
  advance_deduction: decimal.optional(),
}).strict();

const lineBody = z.object({
  sort_order: z.coerce.number().int().optional(),
  item_code: optText,
  description_en: reqText(2000),
  description_ar: optText,
  unit: z.string().trim().min(1).max(20).optional(),
  quantity: decimal.optional(),
  unit_price: decimal.optional(),
  discount_amount: decimal.optional(),
  vat_code: z.string().max(10).optional(),
  vat_exemption_reason: optText,
}).strict();

const paymentBody = z.object({
  payment_date: z.iso.date(),
  amount: decimal,
  method: z.enum(['bank_transfer', 'cheque', 'cash', 'card', 'other']).default('bank_transfer'),
  reference: optText,
  notes: optText,
}).strict();

async function loadInvoice(t: Tx, id: string) {
  const invoice = await getOr404<any>(t, `
    select i.*, c.name_en as customer_name, c.name_ar as customer_name_ar, o.number as original_number,
           ct.number as contract_number, p.number as project_number, p.name as project_name, u.full_name as issued_by_name
    from public.invoices i join public.customers c on c.id = i.customer_id
    left join public.invoices o on o.id = i.original_invoice_id
    left join public.contracts ct on ct.id = i.contract_id
    left join public.projects p on p.id = i.project_id
    left join public.app_users u on u.id = i.issued_by
    where i.id = $1`, [id], 'Invoice');
  const lines = await many(t, 'select * from public.invoice_lines where invoice_id = $1 order by sort_order, created_at', [id]);
  return { invoice, lines };
}

async function loadInvoiceDocument(t: Tx, id: string) {
  const { invoice, lines } = await loadInvoice(t, id);
  const issued = invoice.status === 'issued';
  const seller = issued ? invoice.seller_snapshot : await one(t, 'select * from public.company_settings');
  const buyer = issued ? invoice.buyer_snapshot : await one(t, 'select * from public.customers where id = $1', [invoice.customer_id]);
  const original = invoice.original_invoice_id ? await one(t, 'select number, issue_date from public.invoices where id = $1', [invoice.original_invoice_id]) : null;
  const contract = invoice.contract_id ? await one(t, 'select number from public.contracts where id = $1', [invoice.contract_id]) : null;
  const project = invoice.project_id ? await one(t, 'select number, name from public.projects where id = $1', [invoice.project_id]) : null;
  const stampRow = issued ? await one<{ mime_type: string; data: Buffer }>(t, `select mime_type, data from public.brand_assets where code = 'stamp'`) : null;
  const stampDataUrl = stampRow ? `data:${stampRow.mime_type};base64,${stampRow.data.toString('base64')}` : null;
  const qrDataUrl = invoice.zatca_qr ? await QRCode.toDataURL(invoice.zatca_qr, { errorCorrectionLevel: 'M', margin: 1, width: 360 }) : null;
  return { invoice, lines, seller, buyer, original, contract, project, qrDataUrl, stampDataUrl };
}

const fileName = (inv: any) => {
  const [title] = invoiceTitle(inv);
  return `${(inv.number ?? `${title}-DRAFT`).replace(/[^A-Za-z0-9._-]+/g, '-')}.pdf`;
};

export default async function invoiceRoutes(app: FastifyInstance, { db, storage, pdf }: { db: Db; storage: Storage; pdf: PdfRenderer }) {
  app.get('/invoices', async (req) => {
    const q = listQuery.extend({
      kind: z.enum(['invoice', 'credit_note', 'debit_note', 'proforma']).optional(),
      status: z.enum(['draft', 'issued', 'cancelled']).optional(),
      customer_id: z.uuid().optional(),
      contract_id: z.uuid().optional(),
    }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select i.id, i.number, i.kind, i.zatca_type, i.status, i.customer_id, i.contract_id, i.issue_date, i.due_date, i.currency,
             i.title, i.taxable_amount, i.vat_total, i.total_amount, i.amount_payable, i.amount_paid, i.created_at,
             c.name_en as customer_name, c.name_ar as customer_name_ar, o.number as original_number,
             coalesce((select sum(cn.total_amount) from public.invoices cn where cn.original_invoice_id = i.id and cn.kind = 'credit_note' and cn.status = 'issued'), 0) as credited_amount
      from public.invoices i join public.customers c on c.id = i.customer_id
      left join public.invoices o on o.id = i.original_invoice_id
      where ($1::text is null or i.number ilike '%' || $1 || '%' or i.title ilike '%' || $1 || '%' or c.name_en ilike '%' || $1 || '%' or c.name_ar ilike '%' || $1 || '%')
        and ($2::public.invoice_kind is null or i.kind = $2)
        and ($3::public.invoice_status is null or i.status = $3)
        and ($4::uuid is null or i.customer_id = $4)
        and ($5::uuid is null or i.contract_id = $5)
      order by coalesce(i.issued_at, i.created_at) desc limit $6 offset $7`,
      [q.q || null, q.kind ?? null, q.status ?? null, q.customer_id ?? null, q.contract_id ?? null, q.limit, q.offset]));
  });

  app.post('/invoices', async (req, reply) => {
    const body = headerBody.extend({
      kind: z.enum(['invoice', 'credit_note', 'debit_note', 'proforma']).default('invoice'),
      customer_id: z.uuid().optional(),
      original_invoice_id: z.uuid().optional(),
    }).parse(req.body);
    const created = await tx(db, req, async (t) => {
      const data: Record<string, unknown> = { ...body };
      if (body.kind === 'credit_note' || body.kind === 'debit_note') {
        if (!body.original_invoice_id) throw new HttpError(422, 'Choose the invoice this note refers to', 'rule_violation');
        const orig = await one<any>(t, 'select * from public.invoices where id = $1', [body.original_invoice_id]);
        if (!orig) throw notFound('Original invoice');
        if (orig.kind !== 'invoice' || orig.status !== 'issued') throw new HttpError(422, 'Notes can only refer to an issued invoice', 'rule_violation');
        Object.assign(data, { customer_id: orig.customer_id, contract_id: orig.contract_id, project_id: orig.project_id,
          zatca_type: orig.zatca_type, currency: orig.currency });
      } else {
        if (!body.customer_id) throw new HttpError(422, 'Choose a customer', 'rule_violation');
        delete data.original_invoice_id;
      }
      if (!data.payment_terms_en && !data.payment_terms_ar) {
        const co = await one<any>(t, 'select invoice_terms_en, invoice_terms_ar from public.company_settings');
        data.payment_terms_en = co?.invoice_terms_en ?? undefined;
        data.payment_terms_ar = co?.invoice_terms_ar ?? undefined;
      }
      return insertRow(t, 'invoices', data);
    });
    return reply.status(201).send(created);
  });

  // Progress claim from a contract: one line for the claimed percentage of the contract value, with the contract's retention.
  app.post('/contracts/:id/invoices', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({
      percent: z.coerce.number().gt(0).max(100),
      description_en: z.string().trim().max(2000).optional(),
      description_ar: optText,
      kind: z.enum(['invoice', 'proforma']).default('invoice'),
    }).strict().parse(req.body);
    const created = await tx(db, req, async (t) => {
      const ct = await getOr404<any>(t, 'select * from public.contracts where id = $1', [id], 'Contract');
      const project = await one<any>(t, 'select id from public.projects where contract_id = $1', [id]);
      const claimNo = (await one<{ n: number }>(t, `select count(*)::int + 1 as n from public.invoices where contract_id = $1 and kind = 'invoice' and status <> 'cancelled'`, [id]))!.n;
      const vat = await one<any>(t, 'select code from public.vat_codes where rate = $1 and zatca_category = $2 and is_active limit 1', [ct.vat_rate, Number(ct.vat_rate) > 0 ? 'S' : 'Z']);
      const inv = await insertRow<any>(t, 'invoices', {
        kind: body.kind, customer_id: ct.customer_id, contract_id: ct.id, project_id: project?.id ?? null, currency: ct.currency,
        retention_pct: ct.retention_pct, title: `${ct.title} — Progress claim ${claimNo}`,
      });
      const contractValue = Number(ct.original_value) + Number(ct.approved_variations_value);
      await insertRow(t, 'invoice_lines', {
        invoice_id: inv.id, sort_order: 10, unit: 'LS', quantity: '1',
        unit_price: (Math.round(contractValue * body.percent) / 100).toFixed(2),
        description_en: body.description_en || `Progress claim ${claimNo}: ${body.percent}% of contract ${ct.number} value`,
        description_ar: body.description_ar ?? `المستخلص رقم ${claimNo}: ${body.percent}% من قيمة العقد ${ct.number}`,
        vat_code: vat?.code ?? 'S15',
      });
      return one(t, 'select * from public.invoices where id = $1', [inv.id]);
    });
    return reply.status(201).send(created);
  });

  app.get('/invoices/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const { invoice, lines } = await loadInvoice(t, id);
      const payments = await many(t, `select p.*, u.full_name as created_by_name from public.customer_payments p
        left join public.app_users u on u.id = p.created_by where p.invoice_id = $1 order by p.payment_date, p.created_at`, [id]);
      const notes = await many(t, `select id, number, kind, status, issue_date, total_amount, note_reason from public.invoices
        where original_invoice_id = $1 order by created_at`, [id]);
      const customer = await one(t, 'select * from public.customers where id = $1', [invoice.customer_id]);
      return { ...invoice, lines, payments, notes, customer };
    });
  });

  app.patch('/invoices/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = headerBody.parse(req.body);
    return tx(db, req, async (t) => {
      await updateOrFail(t, 'invoices', id, body, 'Invoice');
      return one(t, 'select * from public.invoices where id = $1', [id]);
    });
  });

  app.post('/invoices/:id/lines', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = z.union([lineBody, z.array(lineBody).min(1).max(500)]).parse(req.body);
    const rows = Array.isArray(body) ? body : [body];
    const result = await tx(db, req, async (t) => {
      const max = await one<{ m: number }>(t, 'select coalesce(max(sort_order), 0)::int as m from public.invoice_lines where invoice_id = $1', [id]);
      let order = max?.m ?? 0;
      for (const r of rows) { order += 10; await insertRow(t, 'invoice_lines', { sort_order: order, ...r, invoice_id: id }); }
      return loadInvoice(t, id);
    });
    return reply.status(201).send(result);
  });

  app.patch('/invoice-lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = lineBody.partial().parse(req.body);
    return tx(db, req, async (t) => {
      const line = await updateOrFail<any>(t, 'invoice_lines', id, body, 'Line');
      return loadInvoice(t, line.invoice_id);
    });
  });

  app.delete('/invoice-lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const r = await t.query('delete from public.invoice_lines where id = $1 returning invoice_id', [id]);
      if (!r.rowCount) throw notFound('Line');
      return loadInvoice(t, r.rows[0].invoice_id);
    });
  });

  // Issue: number, frozen parties, QR, and the archived PDF all commit together or not at all.
  app.post('/invoices/:id/issue', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      await t.query('select public.issue_invoice($1)', [id]);
      const doc = await loadInvoiceDocument(t, id);
      const file = await pdf.render(renderInvoiceHtml(doc, { language: 'bilingual' }));
      const name = fileName(doc.invoice);
      const key = newStorageKey('invoice', id, name);
      await storage.put(key, file, 'application/pdf');
      const att = await insertRow<any>(t, 'attachments', {
        entity_type: 'invoice', entity_id: id, file_name: name, mime_type: 'application/pdf', size_bytes: file.length,
        sha256: sha256(file), storage_path: key, category: 'issued_invoice', is_system_generated: true, uploaded_by: req.user.id,
      });
      await t.query('update public.invoices set pdf_attachment_id = $2 where id = $1', [id, att.id]);
      return one(t, 'select * from public.invoices where id = $1', [id]);
    });
  });

  app.post('/invoices/:id/cancel', async (req) => {
    const { id } = idParam.parse(req.params);
    const { reason } = z.object({ reason: reqText(1000) }).parse(req.body);
    return tx(db, req, async (t) => {
      await t.query('select public.cancel_invoice($1, $2)', [id, reason]);
      return one(t, 'select * from public.invoices where id = $1', [id]);
    });
  });

  app.get('/invoices/:id/pdf', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const { lang } = z.object({ lang: z.enum(['bilingual', 'en', 'ar']).default('bilingual') }).parse(req.query);
    const { html, name } = await tx(db, req, async (t) => {
      const doc = await loadInvoiceDocument(t, id);
      return { html: renderInvoiceHtml(doc, { language: lang as PdfLanguage }), name: fileName(doc.invoice) };
    });
    const file = await pdf.render(html);
    return reply.header('Content-Type', 'application/pdf').header('Content-Disposition', `inline; filename="${name}"`)
      .header('Cache-Control', 'no-store').send(file);
  });

  // Payments received -------------------------------------------------------------
  app.post('/invoices/:id/payments', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = paymentBody.parse(req.body);
    const created = await tx(db, req, async (t) => {
      await getOr404(t, 'select id from public.invoices where id = $1', [id], 'Invoice');
      return insertRow(t, 'customer_payments', { ...body, invoice_id: id });
    });
    return reply.status(201).send(created);
  });

  app.post('/payments/:id/void', async (req) => {
    const { id } = idParam.parse(req.params);
    const { reason } = z.object({ reason: reqText(1000) }).parse(req.body);
    return tx(db, req, async (t) => updateOrFail(t, 'customer_payments', id, { voided_at: new Date().toISOString(), void_reason: reason }, 'Payment'));
  });

  // Receivables summary: issued invoices with money still outstanding, oldest first.
  app.get('/receivables', async (req) => tx(db, req, (t) => many(t, `
    select i.id, i.number, i.kind, i.issue_date, i.due_date, i.currency, i.total_amount, i.amount_payable, i.amount_paid,
           c.id as customer_id, c.name_en as customer_name,
           i.amount_payable - i.amount_paid - coalesce((select sum(cn.total_amount) from public.invoices cn
             where cn.original_invoice_id = i.id and cn.kind = 'credit_note' and cn.status = 'issued'), 0) as outstanding,
           greatest(0, (now() at time zone 'Asia/Riyadh')::date - i.due_date) as days_overdue
    from public.invoices i join public.customers c on c.id = i.customer_id
    where i.status = 'issued' and i.kind in ('invoice', 'debit_note')
      and i.amount_payable - i.amount_paid - coalesce((select sum(cn.total_amount) from public.invoices cn
             where cn.original_invoice_id = i.id and cn.kind = 'credit_note' and cn.status = 'issued'), 0) > 0
    order by i.due_date nulls last`)));
}
