// Expenses with receipts: record, approve, mark paid. Amounts and VAT are what the person typed from the receipt.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { insertRow, many, one, type Db, type Tx } from '../db.js';
import { HttpError, notFound } from '../errors.js';
import { decimal, getOr404, idParam, listQuery, optDate, optText, optUuid, reqText, tx, updateOrFail } from './util.js';

export const EXPENSE_CATEGORIES = ['materials', 'fuel', 'transport', 'equipment_rent', 'subcontract', 'site_supplies', 'meals', 'accommodation',
  'travel', 'government_fees', 'office', 'utilities', 'telecom', 'maintenance', 'general'] as const;

const body = z.object({
  expense_date: optDate,
  description: reqText(500),
  category: z.enum(EXPENSE_CATEGORIES).optional(),
  supplier_id: optUuid,
  supplier_name: optText,
  supplier_vat_number: z.union([z.literal(''), z.string().regex(/^3\d{13}3$/, 'VAT number must be 15 digits starting and ending with 3')]).nullish()
    .transform((v) => (v === '' ? null : v)),
  supplier_invoice_number: optText,
  project_id: optUuid,
  currency: z.string().length(3).toUpperCase().optional(),
  amount: decimal,
  vat_amount: decimal.optional(),
  paid_by: z.enum(['company', 'employee']).optional(),
  payment_method: z.enum(['bank_transfer', 'cash', 'cheque', 'card', 'other']).nullish(),
  notes: optText,
}).strict();

const ACTIONS = { submit: 'submitted', withdraw: 'draft', approve: 'approved', reject: 'rejected', pay: 'paid', cancel: 'cancelled' } as const;

const SELECT = `
  select e.*, u.full_name as created_by_name, d.full_name as decided_by_name, p.number as project_number, p.name as project_name,
         coalesce(s.name_en, e.supplier_name) as payee,
         (select count(*)::int from public.attachments a where a.entity_type = 'expense' and a.entity_id = e.id and a.deleted_at is null) as receipts
  from public.expenses e join public.app_users u on u.id = e.created_by left join public.app_users d on d.id = e.decided_by
  left join public.projects p on p.id = e.project_id left join public.suppliers s on s.id = e.supplier_id`;

const load = (t: Tx, id: string) => getOr404<any>(t, `${SELECT} where e.id = $1`, [id], 'Expense');

export default async function expenseRoutes(app: FastifyInstance, { db }: { db: Db }) {
  app.get('/expenses', async (req) => {
    const q = listQuery.extend({
      status: z.enum(['draft', 'submitted', 'approved', 'rejected', 'paid', 'cancelled']).optional(),
      project_id: z.uuid().optional(),
      mine: z.enum(['true', 'false']).optional(),
    }).parse(req.query);
    return tx(db, req, (t) => many(t, `${SELECT}
      where ($1::text is null or e.description ilike '%' || $1 || '%' or e.number ilike '%' || $1 || '%' or coalesce(s.name_en, e.supplier_name) ilike '%' || $1 || '%')
        and ($2::public.expense_status is null or e.status = $2) and ($3::uuid is null or e.project_id = $3)
        and ($4::boolean is not true or e.created_by = auth.uid())
      order by e.expense_date desc, e.created_at desc limit $5 offset $6`,
      [q.q || null, q.status ?? null, q.project_id ?? null, q.mine === 'true', q.limit, q.offset]));
  });

  // Headline figures for the Expenses page, over the expenses this user can see.
  app.get('/expenses/summary', async (req) => tx(db, req, async (t) => one(t, `
    select
      coalesce(sum(total_amount) filter (where status in ('approved', 'paid')
        and date_trunc('month', expense_date) = date_trunc('month', (now() at time zone 'Asia/Riyadh')::date)), 0) as this_month,
      count(*) filter (where status = 'submitted')::int as waiting_count,
      coalesce(sum(total_amount) filter (where status = 'submitted'), 0) as waiting_amount,
      coalesce(sum(total_amount) filter (where status = 'approved' and paid_by = 'employee'), 0) as owed_to_staff,
      coalesce(sum(vat_amount) filter (where status in ('approved', 'paid')
        and date_trunc('month', expense_date) = date_trunc('month', (now() at time zone 'Asia/Riyadh')::date)), 0) as vat_this_month
    from public.expenses where currency = 'SAR'`)));

  app.post('/expenses', async (req, reply) => {
    const b = body.parse(req.body);
    const created = await tx(db, req, async (t) => { const e = await insertRow<any>(t, 'expenses', b); return load(t, e.id); });
    return reply.status(201).send(created);
  });

  app.get('/expenses/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, (t) => load(t, id));
  });

  app.patch('/expenses/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const b = body.partial().parse(req.body);
    return tx(db, req, async (t) => { await updateOrFail(t, 'expenses', id, b, 'Expense'); return load(t, id); });
  });

  app.post('/expenses/:id/:action', async (req) => {
    const { id, action } = z.object({ id: z.uuid(), action: z.enum(Object.keys(ACTIONS) as [keyof typeof ACTIONS]) }).parse(req.params);
    const { comment } = z.object({ comment: z.string().trim().max(2000).optional() }).parse(req.body ?? {});
    return tx(db, req, async (t) => {
      const r = await t.query('update public.expenses set status = $2, decision_comment = case when $3::text is null then decision_comment else $3 end where id = $1 returning id',
        [id, ACTIONS[action], ['approve', 'reject'].includes(action) ? (comment ?? null) : null]);
      if (!r.rowCount) {
        const visible = await one(t, 'select 1 from public.expenses where id = $1', [id]);
        throw visible ? new HttpError(403, 'You do not have permission for this action', 'forbidden') : notFound('Expense');
      }
      return load(t, id);
    });
  });
}
