// Expenses: a staff member records a receipt, an approver decides, finance marks it paid. Role rules apply (open access off).
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { startServer } from './helpers.js';

let s: Awaited<ReturnType<typeof startServer>>;
const ids: Record<string, string> = {};

beforeAll(async () => { s = await startServer(); });
afterAll(async () => { await s.close(); });

describe('expenses', () => {
  it('a site engineer records an expense; totals are amount + typed VAT', async () => {
    const e = await s.call('site', 'POST', '/expenses', { description: 'Diesel for generator', category: 'fuel', amount: '400', vat_amount: '60', paid_by: 'employee', expense_date: '2026-10-28' });
    expect(e.status).toBe(201);
    expect(e.data).toMatchObject({ status: 'draft', total_amount: '460.00', created_by_name: 'Yousef Site Engineer' });
    expect(e.data.number).toMatch(/^EXP-\d{4}-\d{5}$/);
    ids.e = e.data.id;
    expect((await s.call('site', 'POST', '/expenses', { description: 'x', amount: '-1' })).status).toBe(422);
    expect((await s.call('site', 'POST', '/expenses', { description: 'x', amount: '1', supplier_vat_number: '123' })).status).toBe(400);
  });

  it('only the author and expense readers see it', async () => {
    expect((await s.call('sales', 'GET', `/expenses/${ids.e}`)).status).toBe(404);
    expect((await s.call('finance', 'GET', `/expenses/${ids.e}`)).status).toBe(200);
    expect((await s.call('sales', 'GET', '/expenses')).data.find((x: any) => x.id === ids.e)).toBeUndefined();
  });

  it('keeps the receipt with the expense, hidden from people who cannot see it', async () => {
    const f = new FormData();
    f.append('entity_type', 'expense'); f.append('entity_id', ids.e);
    f.append('file', new Blob([new Uint8Array(Buffer.from('%PDF-1.4 receipt'))], { type: 'application/pdf' }), 'receipt.pdf');
    const up = await s.call('site', 'POST', '/attachments', f);
    expect(up.status).toBe(201);
    expect((await s.call('site', 'GET', `/expenses/${ids.e}`)).data.receipts).toBe(1);
    expect((await s.call('finance', 'GET', `/attachments?entity_type=expense&entity_id=${ids.e}`)).data).toHaveLength(1);
    expect((await s.call('sales', 'GET', `/attachments?entity_type=expense&entity_id=${ids.e}`)).data).toEqual([]);
    expect((await s.call('sales', 'GET', `/attachments/${up.data.id}/download`)).status).toBe(404);
  });

  it('needs a payee to submit, then is frozen', async () => {
    expect((await s.call('site', 'POST', `/expenses/${ids.e}/submit`)).status).toBe(422);
    await s.call('site', 'PATCH', `/expenses/${ids.e}`, { supplier_name: 'ADNOC Station 12' });
    const sub = await s.call('site', 'POST', `/expenses/${ids.e}/submit`);
    expect(sub.data.status).toBe('submitted');
    expect((await s.call('site', 'PATCH', `/expenses/${ids.e}`, { amount: '4000' })).status).toBe(403);
  });

  it('approval needs the permission and a comment to reject; then finance pays', async () => {
    expect((await s.call('site', 'POST', `/expenses/${ids.e}/approve`)).status).toBe(403);
    expect((await s.call('pm', 'POST', `/expenses/${ids.e}/reject`, {})).status).toBe(422);
    const ok = await s.call('pm', 'POST', `/expenses/${ids.e}/approve`);
    expect(ok.data).toMatchObject({ status: 'approved', decided_by_name: 'Faisal Project Manager' });
    const sum = await s.call('finance', 'GET', '/expenses/summary');
    expect(Number(sum.data.owed_to_staff)).toBeGreaterThanOrEqual(460);
    const paid = await s.call('finance', 'POST', `/expenses/${ids.e}/pay`);
    expect(paid.data.status).toBe('paid');
    expect((await s.call('finance', 'POST', `/expenses/${ids.e}/cancel`)).status).toBe(422);
  });

  it('approvers cannot approve their own expense unless self-approval is on', async () => {
    const e = await s.call('pm', 'POST', '/expenses', { description: 'Site visit taxi', amount: '50', supplier_name: 'Careem' });
    await s.call('pm', 'POST', `/expenses/${e.data.id}/submit`);
    expect((await s.call('pm', 'POST', `/expenses/${e.data.id}/approve`)).status).toBe(403);
  });
});
