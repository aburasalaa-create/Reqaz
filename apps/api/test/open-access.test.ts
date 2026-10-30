// Open access: with the company switch on, every user does all daily work and may approve their own requests;
// admin areas stay with administrators. Switching it off restores the role rules.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { startServer } from './helpers.js';

let s: Awaited<ReturnType<typeof startServer>>;

beforeAll(async () => { s = await startServer(); });
afterAll(async () => {
  await s.call('admin', 'PATCH', '/admin/settings', { open_access: false, allow_self_approval: false });
  await s.close();
});

describe('open access', () => {
  it('is off in the test seed, so roles apply', async () => {
    expect(await s.call('site', 'GET', '/customers').then((r) => r.data)).toEqual([]);
    expect((await s.call('site', 'POST', '/customers', { name_en: 'Blocked Co' })).status).toBe(403);
  });

  it('only an administrator can switch it on', async () => {
    expect((await s.call('gm', 'PATCH', '/admin/settings', { open_access: true })).status).toBe(403);
    const r = await s.call('admin', 'PATCH', '/admin/settings', { open_access: true, allow_self_approval: true });
    expect(r.status).toBe(200);
    expect(r.data).toMatchObject({ open_access: true, allow_self_approval: true });
  });

  it('lets any user do the daily work, but not the admin areas', async () => {
    const me = await s.call('site', 'GET', '/me');
    expect(me.data.permissions).toEqual(expect.arrayContaining(['customers.write', 'quotations.approve', 'invoices.issue', 'procurement.approve']));
    expect(me.data.permissions).not.toContain('users.manage');
    expect(me.data.permissions).not.toContain('settings.manage');
    expect(me.data.permissions).not.toContain('audit.read');

    const c = await s.call('site', 'POST', '/customers', { name_en: 'Open Access Trading' });
    expect(c.status).toBe(201);
    expect((await s.call('site', 'GET', '/admin/users')).status).toBe(403);
    expect((await s.call('site', 'PATCH', '/admin/settings', { open_access: false })).status).toBe(403);
  });

  it('lets people approve their own purchase requests', async () => {
    const pr = await s.call('site', 'POST', '/purchase-requests', { title: 'Safety helmets', lines: [{ description: 'Helmet', quantity: '20' }] });
    expect(pr.status).toBe(201);
    await s.call('site', 'POST', `/purchase-requests/${pr.data.id}/submit`);
    const ok = await s.call('site', 'POST', `/purchase-requests/${pr.data.id}/approve`);
    expect(ok.status).toBe(200);
    expect(ok.data.status).toBe('approved');
  });

  it('switching it off restores the roles', async () => {
    await s.call('admin', 'PATCH', '/admin/settings', { open_access: false, allow_self_approval: false });
    expect((await s.call('site', 'POST', '/customers', { name_en: 'Blocked again' })).status).toBe(403);
  });
});
