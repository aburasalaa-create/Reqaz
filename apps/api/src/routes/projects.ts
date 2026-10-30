import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { insertRow, many, one, type Db, type Tx } from '../db.js';
import { notFound } from '../errors.js';
import { approvalInfo } from './approvals.js';
import { decimal, getOr404, idParam, optText, reqText, tx, updateOrFail } from './util.js';

// Project financial position, budget changes and variations.

const n = (v: unknown) => Number(v ?? 0);
const m2 = (v: number) => v.toFixed(2);

/** Every number on the project's financial page, from the database (amounts excl. VAT unless named otherwise). */
export async function projectFinancials(t: Tx, projectId: string) {
  const p = await getOr404<any>(t, `
    select p.*, ct.number as contract_number, ct.original_value, ct.approved_variations_value, ct.retention_pct, ct.advance_payment_pct, ct.currency,
           c.name_en as customer_name, c.name_ar as customer_name_ar, u.full_name as project_manager_name, q.number as quotation_number
    from public.projects p join public.contracts ct on ct.id = p.contract_id join public.customers c on c.id = p.customer_id
    join public.quotations q on q.id = ct.quotation_id left join public.app_users u on u.id = p.project_manager_id where p.id = $1`, [projectId], 'Project');
  const categories = await many<any>(t, `
    select cp.*, cc.name_en, cc.name_ar from public.project_cost_position($1) cp join public.cost_categories cc on cc.code = cp.cost_category
    order by cc.sort_order`, [projectId]);
  const customerPos = await many<any>(t, `
    select id, number, customer_po_number, po_type, status, po_date, amount, vat_amount, total_amount, public.customer_po_billed(id) as billed
    from public.customer_pos where project_id = $1 order by created_at`, [projectId]);
  const sales = await one<any>(t, `
    select coalesce(sum(case when i.kind = 'invoice' and i.billing_type <> 'advance' then i.taxable_amount + i.advance_recovery
                             when i.kind = 'debit_note' then i.taxable_amount
                             when i.kind = 'credit_note' and coalesce(o.billing_type, '') <> 'advance' then -i.taxable_amount else 0 end), 0) as billed,
           coalesce(sum(case when i.kind = 'invoice' and i.billing_type = 'advance' then i.taxable_amount else 0 end), 0) as advances_billed,
           coalesce(sum(case when i.kind = 'invoice' then i.advance_recovery else 0 end), 0) as advances_recovered,
           coalesce(sum(case when i.kind <> 'credit_note' then i.amount_paid + i.retention_received else 0 end), 0) as received,
           coalesce(sum(case when i.kind <> 'credit_note' then i.retention_amount - i.retention_received else 0 end), 0) as retention_held,
           coalesce(sum(case when i.kind <> 'credit_note' then i.amount_payable - i.amount_paid else 0 end), 0) as outstanding
    from public.invoices i left join public.invoices o on o.id = i.original_invoice_id
    where i.project_id = $1 and i.status = 'issued' and i.kind <> 'proforma'`, [projectId]);
  const supplier = await one<any>(t, `
    select coalesce(sum(subtotal) filter (where status = 'posted'), 0) as invoiced,
           coalesce(sum(amount_payable - amount_paid) filter (where status = 'posted'), 0) as payable_open,
           coalesce(sum(amount_paid) filter (where status = 'posted'), 0) as paid,
           count(*) filter (where status = 'draft')::int as drafts
    from public.supplier_invoices where project_id = $1`, [projectId]);
  const orders = await one<any>(t, `
    select coalesce(sum(taxable_amount) filter (where status in ('approved', 'issued', 'partially_received', 'received', 'closed')), 0) as ordered,
           count(*) filter (where status in ('draft', 'pending_approval'))::int as pending,
           count(*) filter (where over_budget and status in ('pending_approval', 'approved', 'issued', 'partially_received'))::int as over_budget
    from public.purchase_orders where project_id = $1`, [projectId]);
  const variations = await one<any>(t, `
    select coalesce(sum(value) filter (where status = 'approved'), 0) as approved_value,
           coalesce(sum(value) filter (where status in ('draft', 'submitted')), 0) as pending_value,
           coalesce(sum(cost_impact) filter (where status = 'approved'), 0) as approved_cost,
           coalesce(sum(cost_impact) filter (where status in ('draft', 'submitted')), 0) as pending_cost,
           count(*) filter (where status in ('draft', 'submitted'))::int as pending_count
    from public.variations where project_id = $1`, [projectId]);
  const expenses = await one<any>(t, `select coalesce(sum(amount) filter (where status in ('approved', 'paid')), 0) as approved,
                                            coalesce(sum(amount) filter (where status = 'submitted'), 0) as waiting
                                     from public.expenses where project_id = $1`, [projectId]);

  const budget = categories.reduce((a, c) => a + n(c.budget), 0);
  const committed = categories.reduce((a, c) => a + n(c.committed), 0);
  const actual = categories.reduce((a, c) => a + n(c.actual), 0);
  const contractValue = n(p.original_value) + n(p.approved_variations_value);
  // Forecast final cost: what is spent and committed, plus the rest of the budget still expected to be spent (never below spent+committed).
  const toComplete = Math.max(budget - actual - committed, 0);
  const forecast = actual + committed + toComplete;
  const revenueBase = contractValue;
  return {
    project: p,
    summary: {
      customer_po_value: m2(customerPos.filter((o) => ['accepted', 'active', 'completed', 'closed'].includes(o.status)).reduce((a, o) => a + n(o.amount), 0)),
      original_contract_value: p.original_value,
      approved_variations: variations?.approved_value ?? '0',
      pending_variations: variations?.pending_value ?? '0',
      pending_variation_count: variations?.pending_count ?? 0,
      contract_value: m2(contractValue),
      approved_budget: p.approved_budget,
      supplier_po_commitments: m2(committed),
      supplier_ordered_total: orders?.ordered ?? '0',
      supplier_invoiced: supplier?.invoiced ?? '0',
      supplier_payable_open: supplier?.payable_open ?? '0',
      supplier_paid: supplier?.paid ?? '0',
      actual_cost: m2(actual),
      expenses_approved: expenses?.approved ?? '0',
      budget_remaining: m2(budget - actual - committed),
      forecast_final_cost: m2(forecast),
      forecast_variance: m2(budget - forecast),
      expected_gross_profit: m2(revenueBase - forecast),
      expected_margin_pct: revenueBase ? ((revenueBase - forecast) / revenueBase * 100).toFixed(1) : null,
      billed_to_customer: sales?.billed ?? '0',
      advances_billed: sales?.advances_billed ?? '0',
      advances_open: m2(n(sales?.advances_billed) - n(sales?.advances_recovered)),
      received_from_customer: sales?.received ?? '0',
      receivable_outstanding: sales?.outstanding ?? '0',
      retention_held_by_customer: sales?.retention_held ?? '0',
      left_to_bill: m2(contractValue - n(sales?.billed)),
      pending_supplier_orders: orders?.pending ?? 0,
      over_budget_orders: orders?.over_budget ?? 0,
    },
    categories,
    customer_pos: customerPos,
  };
}

const VAR_ACTIONS = { submit: 'submitted', withdraw: 'draft', approve: 'approved', reject: 'rejected', cancel: 'cancelled' } as const;

async function loadBudgetChange(t: Tx, id: string) {
  const bc = await getOr404<any>(t, `
    select b.*, p.number as project_number, p.name as project_name, u.full_name as requested_by_name, d.full_name as decided_by_name
    from public.budget_changes b join public.projects p on p.id = b.project_id join public.app_users u on u.id = b.requested_by
    left join public.app_users d on d.id = b.decided_by where b.id = $1`, [id], 'Budget change');
  bc.lines = await many(t, `select l.*, c.name_en, c.name_ar from public.budget_change_lines l join public.cost_categories c on c.code = l.cost_category
                            where l.change_id = $1`, [id]);
  bc.approvals = await approvalInfo(t, 'budget_change', id, bc.lines.reduce((a: number, l: any) => a + Math.abs(n(l.amount)), 0));
  return bc;
}

async function loadVariation(t: Tx, id: string) {
  const v = await getOr404<any>(t, `
    select v.*, p.number as project_number, p.name as project_name, u.full_name as requested_by_name, d.full_name as decided_by_name
    from public.variations v join public.projects p on p.id = v.project_id join public.app_users u on u.id = v.requested_by
    left join public.app_users d on d.id = v.decided_by where v.id = $1`, [id], 'Variation');
  v.approvals = await approvalInfo(t, 'variation', id, Math.max(Math.abs(n(v.value)), Math.abs(n(v.cost_impact))));
  return v;
}

export default async function projectRoutes(app: FastifyInstance, { db }: { db: Db }) {
  app.get('/projects/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const f = await projectFinancials(t, id);
      const budgetChanges = await many(t, `select b.id, b.number, b.reason, b.status, b.total_change, b.created_at, b.variation_id, u.full_name as requested_by_name
                                           from public.budget_changes b join public.app_users u on u.id = b.requested_by where b.project_id = $1 order by b.created_at desc`, [id]);
      const variations = await many(t, `select id, number, title, status, value, cost_impact, customer_reference, created_at
                                        from public.variations where project_id = $1 order by created_at desc`, [id]);
      const purchaseOrders = await many(t, `
        select o.id, o.number, o.status, o.taxable_amount, o.total_amount, o.over_budget, o.issue_date, s.name_en as supplier_name
        from public.purchase_orders o join public.suppliers s on s.id = o.supplier_id
        where o.project_id = $1 and o.status <> 'superseded' order by o.created_at desc`, [id]);
      const invoices = await many(t, `
        select id, number, kind, status, billing_type, issue_date, taxable_amount, total_amount, amount_payable, amount_paid
        from public.invoices where project_id = $1 order by created_at desc`, [id]);
      const supplierInvoices = await many(t, `
        select b.id, b.number, b.supplier_invoice_number, b.status, b.match_status, b.invoice_date, b.subtotal, b.total_amount, b.amount_payable,
               b.amount_paid, s.name_en as supplier_name
        from public.supplier_invoices b join public.suppliers s on s.id = b.supplier_id where b.project_id = $1 order by b.created_at desc`, [id]);
      return { ...f, budget_changes: budgetChanges, variations, purchase_orders: purchaseOrders, invoices, supplier_invoices: supplierInvoices };
    });
  });

  app.post('/projects/:id/status', async (req) => {
    const { id } = idParam.parse(req.params);
    const { status } = z.object({ status: z.enum(['planning', 'active', 'on_hold', 'completed', 'closed', 'cancelled']) }).parse(req.body);
    return tx(db, req, async (t) => { await t.query('select public.set_project_status($1, $2)', [id, status]); return projectFinancials(t, id); });
  });

  // Budget changes --------------------------------------------------------------------
  const bcLine = z.object({ cost_category: z.string().max(30), amount: decimal, note: optText }).strict();

  app.post('/projects/:id/budget-changes', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({ reason: reqText(2000), lines: z.array(bcLine).min(1).max(50) }).strict().parse(req.body);
    const r = await tx(db, req, async (t) => {
      const bc = await insertRow<any>(t, 'budget_changes', { project_id: id, reason: body.reason });
      for (const l of body.lines) await insertRow(t, 'budget_change_lines', { ...l, change_id: bc.id });
      return loadBudgetChange(t, bc.id);
    });
    return reply.status(201).send(r);
  });

  app.get('/budget-changes/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, (t) => loadBudgetChange(t, id));
  });

  app.put('/budget-changes/:id/lines', async (req) => {
    const { id } = idParam.parse(req.params);
    const lines = z.array(bcLine).min(1).max(50).parse(req.body);
    return tx(db, req, async (t) => {
      await t.query('delete from public.budget_change_lines where change_id = $1', [id]);
      for (const l of lines) await insertRow(t, 'budget_change_lines', { ...l, change_id: id });
      return loadBudgetChange(t, id);
    });
  });

  app.post('/budget-changes/:id/:action', async (req) => {
    const { id, action } = z.object({ id: z.uuid(), action: z.enum(Object.keys(VAR_ACTIONS) as [keyof typeof VAR_ACTIONS]) }).parse(req.params);
    const { comment } = z.object({ comment: z.string().trim().max(2000).optional() }).parse(req.body ?? {});
    return tx(db, req, async (t) => {
      await updateOrFail(t, 'budget_changes', id, { status: VAR_ACTIONS[action], decision_comment: comment ?? undefined }, 'Budget change');
      return loadBudgetChange(t, id);
    });
  });

  // Variations ---------------------------------------------------------------------------
  const varBody = z.object({
    title: reqText(300).optional(), description: optText, customer_reference: optText,
    value: decimal.optional(), cost_impact: decimal.optional(), cost_category: z.string().max(30).optional(),
  }).strict();

  app.post('/projects/:id/variations', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = varBody.extend({ title: reqText(300) }).parse(req.body);
    const r = await tx(db, req, async (t) => { const v = await insertRow<any>(t, 'variations', { ...body, project_id: id }); return loadVariation(t, v.id); });
    return reply.status(201).send(r);
  });

  app.get('/variations/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, (t) => loadVariation(t, id));
  });

  app.patch('/variations/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = varBody.parse(req.body);
    return tx(db, req, async (t) => { await updateOrFail(t, 'variations', id, body, 'Variation'); return loadVariation(t, id); });
  });

  app.post('/variations/:id/:action', async (req) => {
    const { id, action } = z.object({ id: z.uuid(), action: z.enum(Object.keys(VAR_ACTIONS) as [keyof typeof VAR_ACTIONS]) }).parse(req.params);
    const { comment } = z.object({ comment: z.string().trim().max(2000).optional() }).parse(req.body ?? {});
    return tx(db, req, async (t) => {
      await updateOrFail(t, 'variations', id, { status: VAR_ACTIONS[action], decision_comment: comment ?? undefined }, 'Variation');
      return loadVariation(t, id);
    });
  });

  // Cost categories (for budgets, requisitions and invoices)
  app.get('/cost-categories', async (req) => tx(db, req, (t) => many(t, 'select * from public.cost_categories order by sort_order')));

  app.get('/projects/:id/ledger', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const r = await one<any>(t, 'select 1 from public.projects where id = $1', [id]);
      if (!r) throw notFound('Project');
      return many(t, `
        select e.number, e.entry_date, e.source_type, e.memo, l.account_code, a.name_en as account_name, l.debit, l.credit, l.cost_category, l.description
        from public.journal_lines l join public.journal_entries e on e.id = l.entry_id join public.accounts a on a.code = l.account_code
        where l.project_id = $1 order by e.entry_date, e.number, l.line_no`, [id]);
    });
  });

}
