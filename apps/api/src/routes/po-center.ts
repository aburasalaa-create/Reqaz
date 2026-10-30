import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { many, one, type Db, inSequence } from '../db.js';
import { decimal, listQuery, tx } from './util.js';

// Purchase Order Center: one dashboard and one search across orders received from customers and orders placed with suppliers.

export default async function poCenterRoutes(app: FastifyInstance, { db }: { db: Db }) {
  app.get('/po-center/summary', async (req) => tx(db, req, async (t) => {
    const [incoming, accepted, awaitingApproval, commitments, deliveries, matching, paymentsDue, overBudget, changed] = await inSequence([
      () => one<any>(t, `select count(*)::int as count, coalesce(sum(amount), 0) as value from public.customer_pos
                    where status in ('received', 'under_review', 'clarification_required')`),
      () => one<any>(t, `select count(*)::int as count, coalesce(sum(amount), 0) as value from public.customer_pos
                    where status in ('accepted', 'active', 'completed', 'closed')`),
      () => one<any>(t, `select count(*)::int as count, coalesce(sum(taxable_amount), 0) as value from public.purchase_orders where status = 'pending_approval'`),
      () => one<any>(t, `select count(distinct o.id)::int as count, coalesce(sum(o.taxable_amount) filter (where l.rn = 1), 0) as ordered,
                           coalesce(sum(round(greatest(l.quantity - public.po_line_received(l.line_ref), 0) * l.net_amount / l.quantity, 2)), 0) as open
                    from public.purchase_orders o
                    join (select x.*, row_number() over (partition by x.order_id order by x.id) as rn from public.purchase_order_lines x) l on l.order_id = o.id
                    where o.status in ('approved', 'issued', 'partially_received', 'received')`),
      () => one<any>(t, `select count(*)::int as count,
                           count(*) filter (where o.delivery_date < (now() at time zone 'Asia/Riyadh')::date)::int as overdue,
                           coalesce(sum((select sum(round(greatest(l.quantity - public.po_line_received(l.line_ref), 0) * l.net_amount / l.quantity, 2))
                                          from public.purchase_order_lines l where l.order_id = o.id)), 0) as value
                    from public.purchase_orders o where o.status in ('issued', 'partially_received')`),
      () => one<any>(t, `select count(*)::int as count, coalesce(sum(total_amount), 0) as value from public.supplier_invoices where status = 'draft'`),
      () => one<any>(t, `select count(*)::int as count, coalesce(sum(amount_payable - amount_paid), 0) as value,
                           count(*) filter (where due_date < (now() at time zone 'Asia/Riyadh')::date)::int as overdue,
                           coalesce(sum(amount_payable - amount_paid) filter (where due_date <= (now() at time zone 'Asia/Riyadh')::date + 7), 0) as due_7_days
                    from public.supplier_invoices where status = 'posted' and amount_payable > amount_paid`),
      () => one<any>(t, `select count(*)::int as count, coalesce(sum(taxable_amount), 0) as value from public.purchase_orders
                    where over_budget and status in ('pending_approval', 'approved', 'issued', 'partially_received', 'received')`),
      () => one<any>(t, `select count(*) filter (where status = 'cancelled')::int as cancelled, count(*) filter (where amends_id is not null and status <> 'cancelled')::int as amended,
                           (select count(*)::int from public.customer_pos where status = 'cancelled') as customer_cancelled,
                           (select count(*)::int from public.customer_pos where po_type = 'amendment') as customer_amended
                    from public.purchase_orders`),
    ] as const);
    const [reviewList, approvalList, deliveryList, matchList, dueList, overBudgetList, changedList] = await inSequence([
      () => many(t, `select o.id, o.number, o.customer_po_number, o.status, o.po_date, o.amount, c.name_en as customer_name
                     from public.customer_pos o join public.customers c on c.id = o.customer_id
                     where o.status in ('received', 'under_review', 'clarification_required') order by o.received_date limit 10`),
      () => many(t, `select o.id, o.number, o.status, o.taxable_amount, o.over_budget, o.submitted_at, s.name_en as supplier_name, p.number as project_number
                     from public.purchase_orders o join public.suppliers s on s.id = o.supplier_id left join public.projects p on p.id = o.project_id
                     where o.status = 'pending_approval' order by o.submitted_at limit 10`),
      () => many(t, `select o.id, o.number, o.status, o.delivery_date, s.name_en as supplier_name, p.number as project_number
                     from public.purchase_orders o join public.suppliers s on s.id = o.supplier_id left join public.projects p on p.id = o.project_id
                     where o.status in ('issued', 'partially_received') order by o.delivery_date nulls last limit 10`),
      () => many(t, `select b.id, b.number, b.supplier_invoice_number, b.total_amount, b.invoice_date, s.name_en as supplier_name, o.number as po_number
                     from public.supplier_invoices b join public.suppliers s on s.id = b.supplier_id left join public.purchase_orders o on o.id = b.po_id
                     where b.status = 'draft' order by b.invoice_date limit 10`),
      () => many(t, `select b.id, b.number, b.supplier_invoice_number, b.due_date, b.amount_payable - b.amount_paid as open, s.name_en as supplier_name
                     from public.supplier_invoices b join public.suppliers s on s.id = b.supplier_id
                     where b.status = 'posted' and b.amount_payable > b.amount_paid order by b.due_date limit 10`),
      () => many(t, `select o.id, o.number, o.status, o.taxable_amount, s.name_en as supplier_name, p.number as project_number
                     from public.purchase_orders o join public.suppliers s on s.id = o.supplier_id left join public.projects p on p.id = o.project_id
                     where o.over_budget and o.status in ('pending_approval', 'approved', 'issued', 'partially_received', 'received') limit 10`),
      () => many(t, `select o.id, o.number, o.status, o.revision_no, o.cancel_reason, o.status_changed_at, s.name_en as supplier_name
                     from public.purchase_orders o join public.suppliers s on s.id = o.supplier_id
                     where o.status = 'cancelled' or o.amends_id is not null order by o.updated_at desc limit 10`),
    ] as const);
    return {
      incoming_awaiting_review: { ...incoming, items: reviewList },
      accepted_customer_po_value: accepted,
      supplier_awaiting_approval: { ...awaitingApproval, items: approvalList },
      supplier_commitments: commitments,
      outstanding_deliveries: { ...deliveries, items: deliveryList },
      supplier_invoices_pending: { ...matching, items: matchList },
      supplier_payments_due: { ...paymentsDue, items: dueList },
      over_budget: { ...overBudget, items: overBudgetList },
      cancelled_and_amended: { ...changed, items: changedList },
    };
  }));

  // Unified search across incoming and outgoing orders.
  app.get('/po-center/orders', async (req) => {
    const q = listQuery.extend({
      direction: z.enum(['all', 'incoming', 'outgoing']).default('all'), status: z.string().max(30).optional(),
      customer_id: z.uuid().optional(), supplier_id: z.uuid().optional(), project_id: z.uuid().optional(),
      from: z.iso.date().optional(), to: z.iso.date().optional(), min_amount: decimal.optional(), max_amount: decimal.optional(),
    }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select * from (
        select 'incoming' as direction, o.id, o.number, o.customer_po_number as party_reference, o.status, o.po_date as order_date, o.amount, o.total_amount,
               c.id as party_id, c.name_en as party_name, p.id as project_id, p.number as project_number, o.created_at
        from public.customer_pos o join public.customers c on c.id = o.customer_id left join public.projects p on p.id = o.project_id
        where $1 in ('all', 'incoming') and ($7::uuid is null) and ($6::uuid is null or o.customer_id = $6)
        union all
        select 'outgoing', o.id, coalesce(o.number, 'Draft'), o.supplier_quote_ref, o.status, coalesce(o.issue_date, o.created_at::date), o.taxable_amount,
               o.total_amount, s.id, s.name_en, p.id, p.number, o.created_at
        from public.purchase_orders o join public.suppliers s on s.id = o.supplier_id left join public.projects p on p.id = o.project_id
        where $1 in ('all', 'outgoing') and o.status <> 'superseded' and ($6::uuid is null) and ($7::uuid is null or o.supplier_id = $7)
      ) x
      where ($2::text is null or x.number ilike '%' || $2 || '%' or x.party_reference ilike '%' || $2 || '%' or x.party_name ilike '%' || $2 || '%'
             or x.project_number ilike '%' || $2 || '%')
        and ($3::text is null or x.status = $3) and ($4::date is null or x.order_date >= $4) and ($5::date is null or x.order_date <= $5)
        and ($8::uuid is null or x.project_id = $8) and ($9::numeric is null or x.amount >= $9) and ($10::numeric is null or x.amount <= $10)
      order by x.created_at desc limit $11 offset $12`,
      [q.direction, q.q || null, q.status ?? null, q.from ?? null, q.to ?? null, q.customer_id ?? null, q.supplier_id ?? null, q.project_id ?? null,
       q.min_amount ?? null, q.max_amount ?? null, q.limit, q.offset]));
  });
}
