// A server without file storage (the production default until a bucket is set up): documents are still issued and can be
// downloaded as PDF or Word, generated from their frozen data; uploads are refused with a clear message.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { startServer } from './helpers.js';

let s: Awaited<ReturnType<typeof startServer>>;

beforeAll(async () => { s = await startServer({ FILE_STORAGE: 'off' }); });
afterAll(async () => { await s.close(); });

describe('without file storage', () => {
  it('tells the browser files are off and refuses uploads', async () => {
    expect((await s.call('site', 'GET', '/me')).data.files_enabled).toBe(false);
    const e = await s.call('site', 'POST', '/expenses', { description: 'Water for site', amount: '30', supplier_name: 'Bakala' });
    const f = new FormData();
    f.append('entity_type', 'expense'); f.append('entity_id', e.data.id);
    f.append('file', new Blob([new Uint8Array(Buffer.from('x'))], { type: 'image/png' }), 'r.png');
    const up = await s.call('site', 'POST', '/attachments', f);
    expect(up.status).toBe(503);
  });

  it('issues an invoice without archiving a file, and downloads it as Word', async () => {
    const inv = await s.call('finance', 'POST', '/invoices', { kind: 'invoice', zatca_type: 'standard', customer_id: '10000000-0000-4000-8000-000000000001' });
    expect(inv.status).toBe(201);
    await s.call('finance', 'POST', `/invoices/${inv.data.id}/lines`, { description_en: 'Consultancy', quantity: '2', unit_price: '500' });
    const iss = await s.call('finance', 'POST', `/invoices/${inv.data.id}/issue`);
    expect(iss.status).toBe(200);
    expect(iss.data.number).toMatch(/^INV-/);
    expect(iss.data.pdf_attachment_id).toBeNull();

    const word = await s.call('finance', 'GET', `/invoices/${inv.data.id}/pdf?format=word`);
    expect(word.status).toBe(200);
    expect(word.headers.get('content-type')).toContain('application/msword');
    expect(word.headers.get('content-disposition')).toContain(`${iss.data.number}.doc`);
    const text = (word.data as Buffer).toString('utf8');
    expect(text).toContain('urn:schemas-microsoft-com:office:word');
    expect(text).toContain(iss.data.number);
    expect(text).toContain('1,150.00');
  });

  it('downloads a quotation as Word without rendering a PDF', async () => {
    const list = await s.call('estimator', 'GET', '/quotations');
    const q = await s.call('estimator', 'GET', `/quotations/${list.data[0].id}`);
    const w = await s.call('estimator', 'GET', `/revisions/${q.data.revisions[0].id}/pdf?format=word&lang=ar`);
    expect(w.status).toBe(200);
    expect(w.headers.get('content-type')).toContain('application/msword');
  });
});
