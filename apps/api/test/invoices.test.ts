// Invoices, credit notes and payments received through the HTTP API: calculation, issue, immutability, QR and access.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { dbClient, startServer } from './helpers.js';

let s: Awaited<ReturnType<typeof startServer>>;
const ids: Record<string, string> = {};
const AL_NOOR = '10000000-0000-4000-8000-000000000001';
const GOVT_NO_ADDRESS = '10000000-0000-4000-8000-000000000002';

/** Decode a ZATCA Phase 1 QR (base64 TLV) into tag → value. */
function decodeTlv(b64: string) {
  const buf = Buffer.from(b64, 'base64');
  const out: Record<number, string> = {};
  for (let i = 0; i < buf.length;) {
    const tag = buf[i]; const len = buf[i + 1];
    out[tag] = buf.subarray(i + 2, i + 2 + len).toString('utf8');
    i += 2 + len;
  }
  return out;
}

beforeAll(async () => { s = await startServer(); });
afterAll(async () => { await s.close(); });

describe('company bank accounts', () => {
  it('validates IBANs and stores several accounts', async () => {
    const bad = await s.call('admin', 'PATCH', '/admin/settings', { bank_accounts: [{ bank_name: 'Test Bank', iban: 'SA12' }] });
    expect(bad.status).toBe(400);
    const ok = await s.call('admin', 'PATCH', '/admin/settings', { bank_accounts: [
      { bank_name: 'Test Bank A', iban: 'sa00 0000 0000 0000 0000 0001'.replace(/\s+/g, '') },
      { bank_name: 'Test Bank B', iban: 'SA0000000000000000000002', show_on_invoices: false },
    ] });
    expect(ok.status).toBe(200);
    expect(ok.data.bank_accounts).toHaveLength(2);
    expect(ok.data.bank_accounts[0]).toMatchObject({ iban: 'SA0000000000000000000001', show_on_invoices: true });
    expect((await s.call('finance', 'PATCH', '/admin/settings', { bank_accounts: [] })).status).toBe(403);
  });
});

describe('customer invoices', () => {
  it('finance prepares a draft with deterministic totals', async () => {
    const inv = await s.call('finance', 'POST', '/invoices', { customer_id: AL_NOOR, title: 'Civil works — March', retention_pct: '10' });
    expect(inv.status).toBe(201);
    expect(inv.data.status).toBe('draft');
    expect(inv.data.number).toBeNull();
    ids.inv = inv.data.id;

    const lines = await s.call('finance', 'POST', `/invoices/${ids.inv}/lines`, [
      { description_en: 'Excavation', description_ar: 'حفر', unit: 'm3', quantity: '3', unit_price: '1000.555', discount_amount: '1.67' },
      { description_en: 'Exempt item', quantity: '1', unit_price: '500', vat_code: 'E' },
    ]);
    expect(lines.status).toBe(201);
    const l = lines.data.lines;
    expect(l[0]).toMatchObject({ gross_amount: '3001.67', net_amount: '3000.00', vat_amount: '450.00', vat_rate: '15.00', vat_category: 'S' });
    expect(l[1]).toMatchObject({ net_amount: '500.00', vat_amount: '0.00', vat_category: 'E' });
    expect(lines.data.invoice).toMatchObject({
      subtotal: '3501.67', discount_total: '1.67', taxable_amount: '3500.00', vat_total: '450.00', total_amount: '3950.00',
      retention_amount: '350.00', amount_payable: '3600.00',
    });
    ids.exemptLine = l[1].id;

    // Totals cannot be written by the client.
    const forged = await s.call('finance', 'PATCH', `/invoices/${ids.inv}`, { total_amount: '1' });
    expect(forged.status).toBe(400);
  });

  it('VAT is totalled per rate, not per line (ZATCA category totals)', async () => {
    const inv = await s.call('finance', 'POST', '/invoices', { customer_id: AL_NOOR });
    const r = await s.call('finance', 'POST', `/invoices/${inv.data.id}/lines`, [
      { description_en: 'A', unit_price: '0.03' }, { description_en: 'B', unit_price: '0.03' }, { description_en: 'C', unit_price: '0.03' },
    ]);
    // Per line round(0.03 × 15%) = 0.00 each; per category round(0.09 × 15%) = 0.01.
    expect(r.data.lines.map((x: any) => x.vat_amount)).toEqual(['0.00', '0.00', '0.00']);
    expect(r.data.invoice.vat_total).toBe('0.01');
  });

  it('refuses to issue until the rules are met', async () => {
    const noReason = await s.call('finance', 'POST', `/invoices/${ids.inv}/issue`);
    expect(noReason.status).toBe(422);
    expect(noReason.data.message).toMatch(/exemption reason/);
    await s.call('finance', 'PATCH', `/invoice-lines/${ids.exemptLine}`, { vat_exemption_reason: 'VATEX-SA-29 Financial services' });

    const govt = await s.call('finance', 'POST', '/invoices', { customer_id: GOVT_NO_ADDRESS });
    await s.call('finance', 'POST', `/invoices/${govt.data.id}/lines`, { description_en: 'Works', unit_price: '100' });
    const noAddress = await s.call('finance', 'POST', `/invoices/${govt.data.id}/issue`);
    expect(noAddress.status).toBe(422);
    expect(noAddress.data.message).toMatch(/address/);

    const empty = await s.call('finance', 'POST', '/invoices', { customer_id: AL_NOOR });
    expect((await s.call('finance', 'POST', `/invoices/${empty.data.id}/issue`)).status).toBe(422);

    const usd = await s.call('finance', 'POST', '/invoices', { customer_id: AL_NOOR, currency: 'USD' });
    await s.call('finance', 'POST', `/invoices/${usd.data.id}/lines`, { description_en: 'Works', unit_price: '100' });
    expect((await s.call('finance', 'POST', `/invoices/${usd.data.id}/issue`)).status).toBe(422);
  });

  it('only issuers can issue; others cannot see or create invoices', async () => {
    expect((await s.call('pm', 'POST', `/invoices/${ids.inv}/issue`)).status).toBe(403);
    expect((await s.call('pm', 'POST', '/invoices', { customer_id: AL_NOOR })).status).toBe(403);
    expect((await s.call('pm', 'GET', `/invoices/${ids.inv}`)).status).toBe(200); // read-only
    expect((await s.call('sales', 'GET', `/invoices/${ids.inv}`)).status).toBe(404);
    expect((await s.call('sales', 'GET', '/invoices')).data).toEqual([]);
    expect((await s.call('sales', 'POST', '/invoices', { customer_id: AL_NOOR })).status).toBe(403);
  });

  it('issues with a number, frozen parties, a ZATCA QR and an archived PDF', async () => {
    const r = await s.call('finance', 'POST', `/invoices/${ids.inv}/issue`);
    expect(r.status).toBe(200);
    expect(r.data.status).toBe('issued');
    expect(r.data.number).toMatch(/^INV-\d{4}-00001$/);
    expect(r.data.seller_snapshot.vat_number).toBe('300000000000003');
    expect(r.data.seller_snapshot.bank_accounts).toHaveLength(2);
    expect(r.data.buyer_snapshot).toMatchObject({ name_en: 'Al Noor Real Estate Development', vat_number: '310000000000003', city: 'Riyadh' });
    expect(r.data.due_date).toBeTruthy();
    expect(r.data.pdf_attachment_id).toBeTruthy();

    const qr = decodeTlv(r.data.zatca_qr);
    expect(qr[1]).toBe(r.data.seller_snapshot.legal_name_ar);
    expect(qr[2]).toBe('300000000000003');
    expect(qr[3]).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    expect(qr[4]).toBe('3950.00');
    expect(qr[5]).toBe('450.00');

    const pdf = await s.call('finance', 'GET', `/invoices/${ids.inv}/pdf`);
    expect(pdf.status).toBe(200);
    expect(pdf.headers.get('content-type')).toBe('application/pdf');
    expect((pdf.data as Buffer).subarray(0, 4).toString()).toBe('%PDF');
  });

  it('an issued invoice can never change', async () => {
    expect((await s.call('finance', 'PATCH', `/invoices/${ids.inv}`, { title: 'Edited' })).status).toBe(403);
    expect((await s.call('finance', 'POST', `/invoices/${ids.inv}/lines`, { description_en: 'More', unit_price: '1' })).status).toBe(403);
    expect((await s.call('finance', 'DELETE', `/invoice-lines/${ids.exemptLine}`)).status).toBe(403);
    const cancel = await s.call('finance', 'POST', `/invoices/${ids.inv}/cancel`, { reason: 'Mistake' });
    expect(cancel.status).toBe(422);
    expect(cancel.data.message).toMatch(/credit note/);

    // Not even directly in the database as a finance user.
    const c = await dbClient();
    try {
      await c.query('begin');
      const u = await c.query(`select id from public.app_users where email = 'finance@reqaz.test'`);
      await c.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: u.rows[0].id, role: 'authenticated' })]);
      await c.query('set local role authenticated');
      await expect(c.query(`update public.invoices set total_amount = 1 where id = $1`, [ids.inv])).rejects.toThrow(/cannot be changed/);
      await c.query('rollback');
    } finally { await c.end(); }
  });

  it('records payments up to the amount outstanding, and voids them', async () => {
    const over = await s.call('finance', 'POST', `/invoices/${ids.inv}/payments`, { payment_date: '2026-10-29', amount: '3600.01' });
    expect(over.status).toBe(422);
    const p = await s.call('finance', 'POST', `/invoices/${ids.inv}/payments`, { payment_date: '2026-10-29', amount: '1000', reference: 'TRX-1' });
    expect(p.status).toBe(201);
    expect(p.data.number).toMatch(/^RCT-\d{4}-00001$/);
    expect((await s.call('finance', 'GET', `/invoices/${ids.inv}`)).data.amount_paid).toBe('1000.00');
    expect((await s.call('sales', 'POST', `/invoices/${ids.inv}/payments`, { payment_date: '2026-10-29', amount: '1' })).status).toBe(404);
    expect((await s.call('pm', 'POST', `/invoices/${ids.inv}/payments`, { payment_date: '2026-10-29', amount: '1' })).status).toBe(403);

    expect((await s.call('finance', 'POST', `/payments/${p.data.id}/void`, { reason: '' })).status).toBe(400);
    const v = await s.call('finance', 'POST', `/payments/${p.data.id}/void`, { reason: 'Bounced cheque' });
    expect(v.status).toBe(200);
    expect(v.data.voided_by).toBeTruthy();
    expect((await s.call('finance', 'GET', `/invoices/${ids.inv}`)).data.amount_paid).toBe('0.00');
    expect((await s.call('finance', 'POST', `/payments/${p.data.id}/void`, { reason: 'Again' })).status).toBe(422);
  });

  it('corrects with a credit note that cannot exceed the invoice', async () => {
    const cn = await s.call('finance', 'POST', '/invoices', { kind: 'credit_note', original_invoice_id: ids.inv, note_reason: 'Quantity correction' });
    expect(cn.status).toBe(201);
    expect(cn.data.customer_id).toBe(AL_NOOR);
    await s.call('finance', 'POST', `/invoices/${cn.data.id}/lines`, { description_en: 'Too much', unit_price: '4000' });
    const big = await s.call('finance', 'POST', `/invoices/${cn.data.id}/issue`);
    expect(big.status).toBe(422);
    const line = (await s.call('finance', 'GET', `/invoices/${cn.data.id}`)).data.lines[0];
    await s.call('finance', 'PATCH', `/invoice-lines/${line.id}`, { unit_price: '100' });
    const ok = await s.call('finance', 'POST', `/invoices/${cn.data.id}/issue`);
    expect(ok.status).toBe(200);
    expect(ok.data.number).toMatch(/^CRN-\d{4}-00001$/);
    expect(ok.data.total_amount).toBe('115.00');

    const ar = await s.call('finance', 'GET', '/receivables');
    expect(ar.data.find((x: any) => x.id === ids.inv).outstanding).toBe('3485.00');

    const noOrig = await s.call('finance', 'POST', '/invoices', { kind: 'credit_note', customer_id: AL_NOOR });
    expect(noOrig.status).toBe(422);
  });

  it('proformas carry no QR and can be cancelled after issue', async () => {
    const pf = await s.call('finance', 'POST', '/invoices', { kind: 'proforma', customer_id: AL_NOOR, currency: 'USD' });
    await s.call('finance', 'POST', `/invoices/${pf.data.id}/lines`, { description_en: 'Advance', unit_price: '1000' });
    const iss = await s.call('finance', 'POST', `/invoices/${pf.data.id}/issue`);
    expect(iss.status).toBe(200);
    expect(iss.data.number).toMatch(/^PRF-\d{4}-00001$/);
    expect(iss.data.zatca_qr).toBeNull();
    expect((await s.call('finance', 'POST', `/invoices/${pf.data.id}/payments`, { payment_date: '2026-10-29', amount: '1' })).status).toBe(422);
    const c = await s.call('finance', 'POST', `/invoices/${pf.data.id}/cancel`, { reason: 'Client changed scope' });
    expect(c.status).toBe(200);
    expect(c.data.status).toBe('cancelled');
  });
});
