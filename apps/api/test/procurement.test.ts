// Purchase request → approval → purchase order → issue → receive, through the HTTP API, with each step done by its role.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { startServer } from './helpers.js';

let s: Awaited<ReturnType<typeof startServer>>;
const ids: Record<string, string> = {};

beforeAll(async () => { s = await startServer(); });
afterAll(async () => { await s.close(); });

describe('procurement', () => {
  it('procurement registers a supplier', async () => {
    const sup = await s.call('procurement', 'POST', '/suppliers', { name_en: 'Al Watan Steel Trading', vat_number: '300111222300003', city: 'Jeddah', payment_terms_days: 45 });
    expect(sup.status).toBe(201);
    ids.supplier = sup.data.id;
  });

  it('a site engineer raises a request; only drafts with items can be submitted', async () => {
    const pr = await s.call('site', 'POST', '/purchase-requests', { title: 'Rebar for foundations', needed_by: '2026-11-15', delivery_location: 'Site A, Jeddah' });
    expect(pr.status).toBe(201);
    expect(pr.data.number).toMatch(/^PR-\d{4}-\d{4}$/);
    ids.pr = pr.data.id;
    expect((await s.call('site', 'POST', `/purchase-requests/${ids.pr}/submit`)).status).toBe(422); // no items

    const l = await s.call('site', 'POST', `/purchase-requests/${ids.pr}/lines`, { description: 'Rebar 16 mm', unit: 'ton', quantity: '12.5', estimated_unit_cost: '2850' });
    expect(l.status).toBe(201);
    expect(l.data.estimated_total).toBe('35625.00');
    await s.call('site', 'POST', `/purchase-requests/${ids.pr}/lines`, { description: 'Binding wire', unit: 'roll', quantity: '20', estimated_unit_cost: '45' });

    // Others cannot edit the requester's draft; sales cannot even see it.
    expect((await s.call('procurement', 'POST', `/purchase-requests/${ids.pr}/lines`, { description: 'x', quantity: '1' })).status).toBe(403);
    expect((await s.call('sales', 'GET', `/purchase-requests/${ids.pr}`)).status).toBe(404);

    const sub = await s.call('site', 'POST', `/purchase-requests/${ids.pr}/submit`);
    expect(sub.status).toBe(200);
    expect(sub.data.status).toBe('submitted');
    expect((await s.call('site', 'POST', `/purchase-requests/${ids.pr}/lines`, { description: 'late', quantity: '1' })).status).toBe(403);
  });

  it('approval needs the permission, a different person, and a comment to reject', async () => {
    expect((await s.call('procurement', 'POST', `/purchase-requests/${ids.pr}/approve`)).status).toBe(403);
    // Ordering before approval is refused.
    expect((await s.call('procurement', 'POST', `/purchase-requests/${ids.pr}/order`, { supplier_id: ids.supplier })).status).toBe(422);

    const own = await s.call('pm', 'POST', '/purchase-requests', { title: 'PM own request', lines: [{ description: 'Cones', quantity: '10' }] });
    await s.call('pm', 'POST', `/purchase-requests/${own.data.id}/submit`);
    expect((await s.call('pm', 'POST', `/purchase-requests/${own.data.id}/approve`)).status).toBe(403);
    expect((await s.call('gm', 'POST', `/purchase-requests/${own.data.id}/reject`, {})).status).toBe(422);
    const rej = await s.call('gm', 'POST', `/purchase-requests/${own.data.id}/reject`, { comment: 'Use stock from store' });
    expect(rej.data.status).toBe('rejected');

    const ok = await s.call('pm', 'POST', `/purchase-requests/${ids.pr}/approve`, { comment: 'OK for pour on 18 Nov' });
    expect(ok.status).toBe(200);
    expect(ok.data).toMatchObject({ status: 'approved', decided_by_name: 'Faisal Project Manager' });
  });

  it('procurement turns the request into a purchase order and issues it', async () => {
    const po = await s.call('procurement', 'POST', `/purchase-requests/${ids.pr}/order`, { supplier_id: ids.supplier });
    expect(po.status).toBe(201);
    expect(po.data).toMatchObject({ status: 'draft', number: null, request_number: expect.stringMatching(/^PR-/) });
    expect(po.data.lines).toHaveLength(2);
    expect(po.data.total_amount).toBe('42003.75'); // (35,625 + 900) × 1.15
    ids.po = po.data.id;
    expect((await s.call('site', 'GET', `/purchase-requests/${ids.pr}`)).data.status).toBe('ordered');
    // A request is ordered once only.
    expect((await s.call('procurement', 'POST', `/purchase-requests/${ids.pr}/order`, { supplier_id: ids.supplier })).status).toBe(422);

    await s.call('procurement', 'PATCH', `/purchase-order-lines/${po.data.lines[0].id}`, { unit_price: '2800' });
    const upd = await s.call('procurement', 'PATCH', `/purchase-orders/${ids.po}`, { supplier_quote_ref: 'Q-2291', terms: 'Delivery to site included.' });
    expect(upd.data.total_amount).toBe('41285.00'); // (35,000 + 900) × 1.15
    expect((await s.call('procurement', 'PATCH', `/purchase-orders/${ids.po}`, { total_amount: '1' })).status).toBe(400);

    expect((await s.call('site', 'POST', `/purchase-orders/${ids.po}/issue`)).status).toBe(403);
    const iss = await s.call('procurement', 'POST', `/purchase-orders/${ids.po}/issue`);
    expect(iss.status).toBe(200);
    expect(iss.data.number).toMatch(/^PO-\d{4}-\d{5}$/);
    expect(iss.data.supplier_snapshot.name_en).toBe('Al Watan Steel Trading');
    expect(iss.data.pdf_attachment_id).toBeTruthy();

    const pdf = await s.call('site', 'GET', `/purchase-orders/${ids.po}/pdf`);
    expect(pdf.headers.get('content-type')).toBe('application/pdf');
  });

  it('issued orders are frozen; status only moves forward, cancel needs a reason', async () => {
    expect((await s.call('procurement', 'PATCH', `/purchase-orders/${ids.po}`, { notes: 'change' })).status).toBe(403);
    expect((await s.call('procurement', 'POST', `/purchase-orders/${ids.po}/lines`, { description: 'extra', quantity: '1' })).status).toBe(403);
    expect((await s.call('procurement', 'POST', `/purchase-orders/${ids.po}/close`)).status).toBe(422); // must be received first
    expect((await s.call('procurement', 'POST', `/purchase-orders/${ids.po}/receive`)).data.status).toBe('received');
    expect((await s.call('procurement', 'POST', `/purchase-orders/${ids.po}/close`)).data.status).toBe('closed');

    const d = await s.call('procurement', 'POST', '/purchase-orders', { supplier_id: ids.supplier });
    expect(d.data.payment_terms).toBe('45 days from invoice');
    expect((await s.call('procurement', 'POST', `/purchase-orders/${d.data.id}/cancel`, {})).status).toBe(422);
    expect((await s.call('procurement', 'POST', `/purchase-orders/${d.data.id}/cancel`, { reason: 'Duplicate' })).data.status).toBe('cancelled');
  });
});
