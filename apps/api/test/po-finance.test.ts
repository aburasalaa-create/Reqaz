// Purchase Order Center acceptance tests (Alaa's list, section H), through the HTTP API with each step done by its role:
//  1 receive a customer PO against an approved quotation   2 compare it with the quotation   3 accept it and create the project
//  4 raise a requisition against the project budget        5 compare supplier quotations     6 approve and issue the supplier PO
//  7 record a partial delivery                             8 match the supplier invoice to the PO and goods received
//  9 post it to accounts payable                          10 bill a progress claim on the customer order
// 11 record a partial customer payment                    12 show the project's financial position and profitability
// plus approval levels, segregation of duties, amendments, variations, bank reconciliation, document versions and the ledger.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { dbClient, startServer } from './helpers.js';

let s: Awaited<ReturnType<typeof startServer>>;
const ids: Record<string, any> = {};
const sum = (rows: any[], f: (r: any) => number) => rows.reduce((a, r) => a + f(r), 0);
const ledger = async (account: string) => {
  const rows = (await s.call('finance', 'GET', `/projects/${ids.project}/ledger`)).data.filter((r: any) => r.account_code === account);
  return sum(rows, (r) => Number(r.debit) - Number(r.credit)).toFixed(2);
};

beforeAll(async () => { s = await startServer(); });
afterAll(async () => { await s.close(); });

describe('Purchase Order Center — acceptance', () => {
  it('setup: an approved quotation and two suppliers', async () => {
    const opp = await s.call('sales', 'POST', '/opportunities', { title: 'GLP warehouse extension', customer_id: '10000000-0000-4000-8000-000000000003', stage: 'qualified' });
    expect(opp.status).toBe(201);
    const q = await s.call('estimator', 'POST', '/quotations', { opportunity_id: opp.data.id, title: 'Warehouse extension — steel works' });
    expect(q.status).toBe(201);
    ids.quotation = q.data.id; ids.rev = q.data.revision_id;
    const lines = await s.call('estimator', 'POST', `/revisions/${ids.rev}/lines`, [
      { description_en: 'Steel structure supply and erection', unit: 'ton', quantity: '100', manual_rate: '9000' },
      { description_en: 'Wall and roof cladding', unit: 'm2', quantity: '2000', manual_rate: '150' },
    ]);
    expect(lines.status).toBe(201);
    const valid = new Date(Date.now() + 30 * 86400000).toISOString().slice(0, 10);
    expect((await s.call('estimator', 'PATCH', `/revisions/${ids.rev}`, { valid_until: valid, payment_terms_en: '10% advance, monthly progress claims, 5% retention' })).status).toBe(200);
    expect((await s.call('estimator', 'POST', `/revisions/${ids.rev}/transition`, { action: 'submit_for_approval' })).status).toBe(200);
    const ok = await s.call('gm', 'POST', `/revisions/${ids.rev}/transition`, { action: 'approve', comment: 'OK' });
    expect(ok.data.status).toBe('approved');
    expect(ok.data.net_amount).toBe('1200000.00');

    const a = await s.call('procurement', 'POST', '/suppliers', { name_en: 'Saudi Steel Sections Co.', vat_number: '301234567800003', city: 'Dammam', payment_terms_days: 30 });
    const b = await s.call('procurement', 'POST', '/suppliers', { name_en: 'Eastern Metals Trading', vat_number: '302345678900003', city: 'Jubail' });
    expect(a.status).toBe(201); expect(b.status).toBe(201);
    ids.supA = a.data.id; ids.supB = b.data.id;
  });

  it('1. sales registers the customer PO against the approved quotation (duplicates refused)', async () => {
    const po = await s.call('sales', 'POST', '/customer-pos', {
      customer_po_number: 'GLP-PO-7781', po_date: new Date().toISOString().slice(0, 10), quotation_id: ids.quotation, copy_quotation_lines: true,
      payment_terms: '10% advance, monthly progress claims, 5% retention', completion_date: '2027-06-30',
    });
    expect(po.status).toBe(201);
    expect(po.data).toMatchObject({ status: 'received', customer_name: 'Gulf Logistics Park Co.', quotation_revision_id: ids.rev, amount: '1200000.00', vat_amount: '180000.00' });
    expect(po.data.number).toMatch(/^CPO-\d{4}-\d{5}$/);
    expect(po.data.lines).toHaveLength(2);
    ids.cpo = po.data.id; ids.cpoLines = po.data.lines.map((l: any) => l.id);

    const dup = await s.call('sales', 'POST', '/customer-pos', { customer_po_number: 'GLP-PO-7781', po_date: '2026-10-30', customer_id: '10000000-0000-4000-8000-000000000003' });
    expect(dup.status).toBe(409);

    // The customer ordered less cladding than quoted.
    const upd = await s.call('sales', 'PATCH', `/customer-po-lines/${ids.cpoLines[1]}`, { quantity: '1800' });
    expect(upd.data).toMatchObject({ amount: '1170000.00', vat_amount: '175500.00', total_amount: '1345500.00' });
  });

  it('2. the comparison shows the differences in scope, quantity, price, VAT and totals', async () => {
    const r = await s.call('sales', 'POST', `/customer-pos/${ids.cpo}/review`);
    expect(r.data.status).toBe('under_review');
    const c = r.data.comparison;
    expect(c.quotation.number).toMatch(/^QTN-/);
    expect(c.differences).toBeGreaterThanOrEqual(3);
    const cladding = c.lines.find((l: any) => l.description === 'Wall and roof cladding');
    expect(cladding).toMatchObject({ quoted_qty: '2000.000', po_qty: '1800.000', issues: ['quantity'], difference: '-30000.00' });
    expect(c.summary.find((x: any) => x.field === 'amount')).toMatchObject({ quoted: '1200000.00', ordered: '1170000.00', match: false });
    expect(c.summary.find((x: any) => x.field === 'vat_rate').match).toBe(true);
    expect(c.summary.find((x: any) => x.field === 'payment_terms').match).toBe(true);
    expect(c.partial).toBe(true);
  });

  it('3. acceptance needs authority; then the order becomes the project', async () => {
    expect((await s.call('gm', 'POST', `/customer-pos/${ids.cpo}/convert`, {})).status).toBe(422); // not accepted yet
    expect((await s.call('sales', 'POST', `/customer-pos/${ids.cpo}/accept`)).status).toBe(403);
    const acc = await s.call('gm', 'POST', `/customer-pos/${ids.cpo}/accept`, { note: 'Reduced cladding agreed by phone' });
    expect(acc.data).toMatchObject({ status: 'accepted', accepted_by_name: 'Khalid General Manager' });
    expect(acc.data.approvals.history.map((h: any) => h.action)).toEqual(['submitted', 'approved']);
    // Accepted orders are frozen.
    expect((await s.call('sales', 'PATCH', `/customer-pos/${ids.cpo}`, { payment_terms: 'changed' })).status).toBe(403);

    const pm = (await s.call('pm', 'GET', '/me')).data.id;
    const conv = await s.call('gm', 'POST', `/customer-pos/${ids.cpo}/convert`, {
      project_name: 'GLP warehouse extension', project_manager_id: pm, start_date: '2026-11-01', target_completion_date: '2027-06-30',
      retention_pct: '5', advance_payment_pct: '10' });
    expect(conv.status).toBe(200);
    expect(conv.data).toMatchObject({ status: 'active', project_status: 'active' });
    expect(conv.data.project_number).toMatch(/^PRJ-/);
    ids.project = conv.data.project_id;
    expect((await s.call('sales', 'GET', `/quotations/${ids.quotation}`)).data.status).toBe('won');
  });

  it('4. budget is set by an approved budget change, then a requisition is raised against it', async () => {
    const bc = await s.call('pm', 'POST', `/projects/${ids.project}/budget-changes`, {
      reason: 'Initial cost budget', lines: [{ cost_category: 'materials', amount: '600000' }, { cost_category: 'subcontract', amount: '250000' }] });
    expect(bc.status).toBe(201);
    expect(bc.data.total_change).toBe('850000.00');
    await s.call('pm', 'POST', `/budget-changes/${bc.data.id}/submit`);
    expect((await s.call('pm', 'POST', `/budget-changes/${bc.data.id}/approve`)).status).toBe(403);
    expect((await s.call('gm', 'POST', `/budget-changes/${bc.data.id}/approve`)).data.status).toBe('approved');

    const pr = await s.call('site', 'POST', '/purchase-requests', {
      title: 'Steel sections and bolts', project_id: ids.project, cost_category: 'materials', needed_by: '2026-12-01',
      technical_spec: 'S275JR to SASO, mill certificates required', justification: 'Phase 1 frames',
      lines: [{ description: 'Steel sections S275', unit: 'ton', quantity: '80', estimated_unit_cost: '6500' },
              { description: 'High-strength bolt sets', unit: 'LS', quantity: '1', estimated_unit_cost: '12000' }] });
    expect(pr.status).toBe(201);
    ids.pr = pr.data.id;
    const sub = await s.call('site', 'POST', `/purchase-requests/${ids.pr}/submit`);
    expect(sub.data.budget_check).toMatchObject({ cost_category: 'materials', budget: 600000, available: 600000, requested: 532000, over_budget: false });
    expect((await s.call('pm', 'POST', `/purchase-requests/${ids.pr}/approve`)).data.status).toBe('approved');
    ids.prLines = sub.data.lines.map((l: any) => l.id);
  });

  it('5. procurement records and compares supplier quotations', async () => {
    const qa = await s.call('procurement', 'POST', `/purchase-requests/${ids.pr}/quotes`, {
      supplier_id: ids.supA, quote_ref: 'SSS-Q-551', delivery_days: 14, payment_terms: '30 days', warranty: '12 months', technical_compliance: 'compliant',
      lines: [{ request_line_id: ids.prLines[0], unit_price: '6400' }, { request_line_id: ids.prLines[1], unit_price: '11000' }] });
    expect(qa.status).toBe(201);
    const qb = await s.call('procurement', 'POST', `/purchase-requests/${ids.pr}/quotes`, {
      supplier_id: ids.supB, quote_ref: 'EMT-7', delivery_days: 7, payment_terms: '50% advance', technical_compliance: 'non_compliant',
      commercial_notes: 'Offers S235 instead of S275',
      lines: [{ request_line_id: ids.prLines[0], unit_price: '6300' }, { request_line_id: ids.prLines[1], unit_price: '12500' }] });
    const cmp = qb.data;
    const a = cmp.quotes.find((q: any) => q.supplier_id === ids.supA);
    const b = cmp.quotes.find((q: any) => q.supplier_id === ids.supB);
    expect(a).toMatchObject({ subtotal: '523000.00', vat_total: '78450.00', total_amount: '601450.00', lowest_total: true });
    expect(b).toMatchObject({ subtotal: '516500.00', lowest_total: false, fastest_delivery: true });
    expect(cmp.comparison[0].lowest_quote_id).toBe(b.id); // cheapest steel price, but not compliant
    ids.quoteA = a.id; ids.quoteB = b.id;

    expect((await s.call('procurement', 'POST', `/supplier-quotes/${ids.quoteB}/select`, {})).status).toBe(422); // needs a reason
    const sel = await s.call('procurement', 'POST', `/supplier-quotes/${ids.quoteA}/select`, {});
    expect(sel.status).toBe(201);
    ids.po = sel.data.purchase_order_id;
    expect((await s.call('procurement', 'GET', `/purchase-requests/${ids.pr}`)).data.status).toBe('ordered');
    // The comparison is closed now.
    expect((await s.call('procurement', 'PATCH', `/supplier-quotes/${ids.quoteB}`, { warranty: 'x' })).status).toBe(403);
  });

  it('6. the supplier PO goes through approval levels by value before it is issued', async () => {
    const roles = (await s.call('admin', 'GET', '/admin/roles')).data;
    const role = (code: string) => roles.find((r: any) => r.code === code).id;
    const lv = await s.call('admin', 'PUT', '/approval-levels/purchase_order', [
      { min_amount: '0', role_id: role('project_management') }, { min_amount: '500000', role_id: role('general_manager') }]);
    expect(lv.data).toHaveLength(2);

    const po = (await s.call('procurement', 'GET', `/purchase-orders/${ids.po}`)).data;
    expect(po).toMatchObject({ status: 'draft', taxable_amount: '523000.00', total_amount: '601450.00', supplier_quote_ref: 'SSS-Q-551' });
    expect((await s.call('procurement', 'POST', `/purchase-orders/${ids.po}/issue`)).status).toBe(422);
    const sub = await s.call('procurement', 'POST', `/purchase-orders/${ids.po}/submit`);
    expect(sub.data).toMatchObject({ status: 'pending_approval', over_budget: false });
    expect(sub.data.approvals.levels.map((l: any) => l.role_name)).toEqual(['Project Management', 'General Manager']);

    expect((await s.call('site', 'POST', `/purchase-orders/${ids.po}/approve`)).status).toBe(403);
  });

  it('6b. level 1 by the project manager, level 2 by the general manager, then issue', async () => {
    let po = (await s.call('procurement', 'GET', `/purchase-orders/${ids.po}`)).data;
    if (po.status === 'pending_approval' && po.approvals.levels.every((l: any) => !l.signed)) {
      po = (await s.call('pm', 'POST', `/purchase-orders/${ids.po}/approve`, { comment: 'Within budget' })).data;
    }
    expect(po.status).toBe('pending_approval');
    expect(po.approvals.levels.map((l: any) => l.signed)).toEqual([true, false]);
    expect((await s.call('pm', 'POST', `/purchase-orders/${ids.po}/approve`)).status).toBe(403); // level 2 needs the GM
    po = (await s.call('gm', 'POST', `/purchase-orders/${ids.po}/approve`)).data;
    expect(po.status).toBe('approved');
    const iss = await s.call('procurement', 'POST', `/purchase-orders/${ids.po}/issue`);
    expect(iss.data.status).toBe('issued');
    expect(iss.data.number).toMatch(/^PO-\d{4}-\d{5}$/);
    ids.poNumber = iss.data.number; ids.poLines = iss.data.lines;
    // Issued orders cannot be edited.
    expect((await s.call('procurement', 'PATCH', `/purchase-orders/${ids.po}`, { notes: 'x' })).status).toBe(403);
    await s.call('admin', 'PUT', '/approval-levels/purchase_order', []);
  });

  it('7. a partial delivery is received; over-receipt is refused', async () => {
    const [steel, bolts] = ids.poLines;
    expect((await s.call('site', 'POST', `/purchase-orders/${ids.po}/receipts`, { lines: [{ po_line_id: steel.id, quantity: '81' }] })).status).toBe(422);
    const g = await s.call('site', 'POST', `/purchase-orders/${ids.po}/receipts`, {
      delivery_note_ref: 'DN-SSS-1201', lines: [{ po_line_id: steel.id, quantity: '50' }, { po_line_id: bolts.id, quantity: '1' }] });
    expect(g.status).toBe(201);
    expect(g.data.number).toMatch(/^GRN-\d{4}-\d{5}$/);
    const po = (await s.call('procurement', 'GET', `/purchase-orders/${ids.po}`)).data;
    expect(po.status).toBe('partially_received');
    expect(po.lines.map((l: any) => l.received_qty)).toEqual(['50.000', '1.000']);
    expect((await s.call('site', 'POST', `/purchase-orders/${ids.po}/receipts`, { lines: [{ po_line_id: steel.id, quantity: '31' }] })).status).toBe(422);
  });

  it('8. the supplier invoice is matched against the PO and goods received', async () => {
    const bill = await s.call('procurement', 'POST', '/supplier-invoices', { po_id: ids.po, supplier_invoice_number: 'SSS-INV-1001', invoice_date: '2026-11-20' });
    expect(bill.status).toBe(201);
    expect(bill.data).toMatchObject({ status: 'draft', subtotal: '331000.00', vat_total: '49650.00', total_amount: '380650.00' });
    expect(bill.data.match.status).toBe('matched');
    ids.bill = bill.data.id;

    // Invoicing more steel than has arrived (55 t billed, 50 t delivered) does not match.
    const bad = await s.call('procurement', 'POST', '/supplier-invoices', { po_id: ids.po, supplier_invoice_number: 'SSS-INV-1002', invoice_date: '2026-11-21',
      lines: [{ po_line_id: ids.poLines[0].id, description: 'Steel sections S275', quantity: '55', unit_price: '6400' }] });
    expect(bad.data.match.status).toBe('variance');
    expect(bad.data.match.lines[0]).toMatchObject({ qty_ok: false, price_ok: true });
    expect((await s.call('procurement', 'POST', `/supplier-invoices/${bad.data.id}/post`)).status).toBe(422);
    expect((await s.call('procurement', 'POST', `/supplier-invoices/${bad.data.id}/cancel`, { reason: 'Sent before delivery' })).data.status).toBe('cancelled');
  });

  it('9. posting puts it in accounts payable; a part payment reduces it', async () => {
    const p = await s.call('procurement', 'POST', `/supplier-invoices/${ids.bill}/post`);
    expect(p.data).toMatchObject({ status: 'posted', match_status: 'matched', amount_payable: '380650.00' });
    expect((await s.call('procurement', 'PATCH', `/supplier-invoices/${ids.bill}`, { notes: 'x' })).status).toBe(403);
    expect(await ledger('2150')).toBe('0.00');          // goods received not invoiced: cleared
    expect(await ledger('2000')).toBe('-380650.00');    // accounts payable
    expect(await ledger('5000')).toBe('331000.00');     // materials cost from the delivery

    const acct = await s.call('admin', 'POST', '/accounts', { code: '1020', name_en: 'Al Rajhi current account', type: 'asset', is_bank: true, bank_name: 'Al Rajhi Bank' });
    expect(acct.status).toBe(201);
    expect((await s.call('finance', 'POST', '/supplier-payments', { invoice_id: ids.bill, payment_date: '2026-11-25', amount: '400000' })).status).toBe(422);
    const pay = await s.call('finance', 'POST', '/supplier-payments', { invoice_id: ids.bill, payment_date: '2026-11-25', amount: '200000', bank_account_code: '1020', reference: 'TRF-889' });
    expect(pay.status).toBe(201);
    ids.supplierPayment = pay.data.id;
    expect(await ledger('2000')).toBe('-180650.00');
  });

  it('10. advance and progress invoices are billed against the customer order', async () => {
    const adv = await s.call('finance', 'POST', `/customer-pos/${ids.cpo}/invoices`, { type: 'advance', percent: '10' });
    expect(adv.status).toBe(201);
    let inv = (await s.call('finance', 'GET', `/invoices/${adv.data.invoice_id}`)).data;
    expect(inv).toMatchObject({ billing_type: 'advance', taxable_amount: '117000.00', vat_total: '17550.00', total_amount: '134550.00', retention_amount: '0.00' });
    expect((await s.call('finance', 'POST', `/invoices/${adv.data.invoice_id}/issue`)).status).toBe(200);
    const advPay = await s.call('finance', 'POST', `/invoices/${adv.data.invoice_id}/payments`, { payment_date: '2026-11-05', amount: '134550', bank_account_code: '1020' });
    expect(advPay.status).toBe(201);

    const claim = await s.call('finance', 'POST', `/customer-pos/${ids.cpo}/invoices`, { type: 'progress', lines: [
      { po_line_id: ids.cpoLines[0], cumulative_pct: '40' }, { po_line_id: ids.cpoLines[1], cumulative_pct: '25' }] });
    expect(claim.status).toBe(201);
    ids.claim = claim.data.invoice_id;
    inv = (await s.call('finance', 'GET', `/invoices/${ids.claim}`)).data;
    expect(inv).toMatchObject({
      billing_type: 'progress', claim_no: 1, customer_po_number: 'GLP-PO-7781', subtotal: '427500.00', advance_recovery: '42750.00',
      taxable_amount: '384750.00', vat_total: '57712.50', total_amount: '442462.50', retention_amount: '19237.50', amount_payable: '423225.00' });
    const iss = await s.call('finance', 'POST', `/invoices/${ids.claim}/issue`);
    expect(iss.status).toBe(200);
    // The next claim starts from what has been claimed.
    const again = await s.call('finance', 'POST', `/customer-pos/${ids.cpo}/invoices`, { type: 'progress', lines: [{ po_line_id: ids.cpoLines[0], cumulative_pct: '40' }] });
    expect(again.status).toBe(422);
  });

  it('11. a partial customer payment is recorded', async () => {
    const pay = await s.call('finance', 'POST', `/invoices/${ids.claim}/payments`, { payment_date: '2026-12-10', amount: '200000', bank_account_code: '1020' });
    expect(pay.status).toBe(201);
    const inv = (await s.call('finance', 'GET', `/invoices/${ids.claim}`)).data;
    expect(inv).toMatchObject({ amount_paid: '200000.00' });
    const cpo = (await s.call('finance', 'GET', `/customer-pos/${ids.cpo}`)).data;
    expect(cpo.billing).toMatchObject({ billed: '427500.00', remaining: '742500.00', received: '334550.00', outstanding: '223225.00', retention_held: '19237.50' });
  });

  it('a variation raises the contract value and, with its cost, the budget', async () => {
    const v = await s.call('pm', 'POST', `/projects/${ids.project}/variations`, {
      title: 'Additional mezzanine', customer_reference: 'GLP-VO-01', value: '50000', cost_impact: '30000', cost_category: 'subcontract' });
    expect(v.data.number).toMatch(/^VO-\d{4}-\d{4}$/);
    await s.call('pm', 'POST', `/variations/${v.data.id}/submit`);
    expect((await s.call('gm', 'POST', `/variations/${v.data.id}/approve`)).data.status).toBe('approved');
  });

  it('12. the project shows its financial position and profitability', async () => {
    const r = await s.call('pm', 'GET', `/projects/${ids.project}`);
    expect(r.status).toBe(200);
    expect(r.data.summary).toMatchObject({
      customer_po_value: '1170000.00', original_contract_value: '1200000.00', approved_variations: '50000.00', contract_value: '1250000.00',
      approved_budget: '880000.00', supplier_po_commitments: '192000.00', supplier_invoiced: '331000.00', actual_cost: '331000.00',
      budget_remaining: '357000.00', forecast_final_cost: '880000.00', expected_gross_profit: '370000.00', expected_margin_pct: '29.6',
      billed_to_customer: '427500.00', advances_billed: '117000.00', advances_open: '74250.00', received_from_customer: '334550.00',
      receivable_outstanding: '223225.00', retention_held_by_customer: '19237.50', left_to_bill: '822500.00', supplier_payable_open: '180650.00',
    });
    const materials = r.data.categories.find((c: any) => c.cost_category === 'materials');
    expect(materials).toMatchObject({ budget: '600000.00', committed: '192000.00', actual: '331000.00', invoiced: '331000.00', available: '77000.00' });
    // A purchase order never changes the budget.
    expect(r.data.categories.find((c: any) => c.cost_category === 'subcontract').budget).toBe('280000.00');

    // The ledger agrees, project by project.
    expect(await ledger('4000')).toBe('-427500.00');   // revenue
    expect(await ledger('2200')).toBe('-74250.00');    // advances still owed back to the customer
    expect(await ledger('1100')).toBe('223225.00');    // receivable
    expect(await ledger('1110')).toBe('19237.50');     // retention held by the customer
  });

  it('amending the supplier PO keeps the number, replaces the original and moves the commitment', async () => {
    const am = await s.call('procurement', 'POST', `/purchase-orders/${ids.po}/amend`);
    expect(am.status).toBe(201);
    expect(am.data).toMatchObject({ status: 'draft', revision_no: 1, amends_id: ids.po });
    const steel = am.data.lines.find((l: any) => l.description === 'Steel sections S275');
    expect((await s.call('procurement', 'PATCH', `/purchase-order-lines/${steel.id}`, { quantity: '45' })).status).toBe(200); // below received
    await s.call('procurement', 'POST', `/purchase-orders/${am.data.id}/submit`);
    await s.call('pm', 'POST', `/purchase-orders/${am.data.id}/approve`);
    expect((await s.call('procurement', 'POST', `/purchase-orders/${am.data.id}/issue`)).status).toBe(422);
    await s.call('procurement', 'POST', `/purchase-orders/${am.data.id}/cancel`, { reason: 'Quantity below delivered' });

    const am2 = await s.call('procurement', 'POST', `/purchase-orders/${ids.po}/amend`);
    const steel2 = am2.data.lines.find((l: any) => l.description === 'Steel sections S275');
    await s.call('procurement', 'PATCH', `/purchase-order-lines/${steel2.id}`, { quantity: '85' });
    await s.call('procurement', 'POST', `/purchase-orders/${am2.data.id}/submit`);
    expect((await s.call('pm', 'POST', `/purchase-orders/${am2.data.id}/approve`)).data.status).toBe('approved');
    const iss = await s.call('procurement', 'POST', `/purchase-orders/${am2.data.id}/issue`);
    expect(iss.data).toMatchObject({ status: 'partially_received', number: `${ids.poNumber}-A1` });
    expect((await s.call('procurement', 'GET', `/purchase-orders/${ids.po}`)).data.status).toBe('superseded');
    const f = (await s.call('pm', 'GET', `/projects/${ids.project}`)).data;
    expect(f.summary.supplier_po_commitments).toBe('224000.00'); // 35 t × 6,400 still to come
  });

  it('segregation of duties stops self-approval even when self-approval is allowed', async () => {
    await s.call('admin', 'PATCH', '/admin/settings', { allow_self_approval: true, segregation_of_duties: true });
    const bc = await s.call('gm', 'POST', `/projects/${ids.project}/budget-changes`, { reason: 'Move to equipment', lines: [
      { cost_category: 'general', amount: '0.01' }] });
    await s.call('gm', 'POST', `/budget-changes/${bc.data.id}/submit`);
    expect((await s.call('gm', 'POST', `/budget-changes/${bc.data.id}/approve`)).status).toBe(403);
    await s.call('admin', 'PATCH', '/admin/settings', { allow_self_approval: false, segregation_of_duties: false });
  });

  it('bank reconciliation matches the statement to the ledger and books bank charges', async () => {
    const add = await s.call('finance', 'POST', '/bank-reconciliation/1020/lines', [
      { txn_date: '2026-11-05', description: 'GLP advance', amount: '134550' },
      { txn_date: '2026-11-25', description: 'TRF-889 Saudi Steel', amount: '-200000' },
      { txn_date: '2026-12-10', description: 'GLP claim 1', amount: '200000' },
      { txn_date: '2026-12-31', description: 'Bank charges', amount: '-57.50' }]);
    expect(add.status).toBe(201);
    let rec = (await s.call('finance', 'GET', '/bank-reconciliation/1020')).data;
    expect(rec.summary.reconciled).toBe(false);
    for (const line of rec.statement.filter((x: any) => x.suggestions?.length)) {
      expect((await s.call('finance', 'POST', `/bank-statement-lines/${line.id}/match`, { journal_line_id: line.suggestions[0] })).status).toBe(200);
    }
    const charge = rec.statement.find((x: any) => x.description === 'Bank charges');
    expect((await s.call('finance', 'POST', `/bank-statement-lines/${charge.id}/post`, { account: '6000', memo: 'Monthly fees' })).status).toBe(200);
    rec = (await s.call('finance', 'GET', '/bank-reconciliation/1020')).data;
    expect(rec.summary).toMatchObject({ statement_balance: '134492.50', ledger_balance: '134492.50', difference: '0.00', reconciled: true });
    expect((await s.call('site', 'GET', '/bank-reconciliation/1020')).status).toBe(403);
  });

  it('documents keep their versions', async () => {
    const up = async (replaces?: string) => {
      const f = new FormData();
      f.append('entity_type', 'customer_po'); f.append('entity_id', ids.cpo); f.append('document_type', 'customer_po');
      if (replaces) f.append('replaces_id', replaces);
      f.append('file', new Blob([new Uint8Array(Buffer.from('%PDF-1.4 order'))], { type: 'application/pdf' }), 'GLP-PO-7781.pdf');
      return s.call('sales', 'POST', '/attachments', f);
    };
    const v1 = await up();
    expect(v1.status).toBe(201);
    const v2 = await up(v1.data.id);
    expect(v2.data).toMatchObject({ version: 2, document_type: 'customer_po' });
    expect((await up(v1.data.id)).status).toBe(422); // v1 already has a newer version
    const latest = await s.call('sales', 'GET', `/attachments?entity_type=customer_po&entity_id=${ids.cpo}`);
    expect(latest.data.map((a: any) => a.version)).toEqual([2]);
    const all = await s.call('sales', 'GET', `/attachments?entity_type=customer_po&entity_id=${ids.cpo}&history=true`);
    expect(all.data).toHaveLength(2);
  });

  it('every journal entry balances, the trial balance balances, and the ledger cannot be edited', async () => {
    const tb = (await s.call('finance', 'GET', '/trial-balance')).data;
    expect(tb.balanced).toBe(true);
    const c = await dbClient();
    try {
      const r = await c.query(`select e.number from public.journal_entries e join public.journal_lines l on l.entry_id = e.id
                               group by e.id having sum(l.debit) <> sum(l.credit) or sum(l.debit) <> e.total`);
      expect(r.rows).toEqual([]);
      await expect(c.query('update public.journal_lines set debit = debit + 1 where debit > 0')).rejects.toThrow(/cannot be changed/);
    } finally { await c.end(); }
    expect((await s.call('site', 'GET', '/journals')).data).toEqual([]); // no ledger access without accounting.read (RLS)
  });

  it('the PO Center dashboard and search see both directions', async () => {
    const d = (await s.call('gm', 'GET', '/po-center/summary')).data;
    expect(Number(d.accepted_customer_po_value.value)).toBeGreaterThanOrEqual(1170000);
    expect(d.outstanding_deliveries.items.some((o: any) => o.number === `${ids.poNumber}-A1`)).toBe(true);
    expect(d.supplier_payments_due.items.some((b: any) => b.supplier_invoice_number === 'SSS-INV-1001')).toBe(true);
    const found = (await s.call('gm', 'GET', `/po-center/orders?q=GLP-PO-7781`)).data;
    expect(found.map((o: any) => o.direction)).toContain('incoming');
    const out = (await s.call('gm', 'GET', `/po-center/orders?direction=outgoing&supplier_id=${ids.supA}`)).data;
    expect(out.map((o: any) => o.number)).toContain(`${ids.poNumber}-A1`);
  });
});
