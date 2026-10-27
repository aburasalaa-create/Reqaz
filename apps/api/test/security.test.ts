// Authorization is enforced by the API *and* by PostgreSQL row-level security.
// These tests try to read and change records the user is not entitled to.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type pg from 'pg';
import { asUser, dbClient, startServer, USERS } from './helpers.js';

let s: Awaited<ReturnType<typeof startServer>>;
let c: pg.Client;
const CUSTOMER = '10000000-0000-4000-8000-000000000001';
const OPP = '20000000-0000-4000-8000-000000000001';

beforeAll(async () => { s = await startServer(); c = await dbClient(); });
afterAll(async () => { await s.close(); await c.end(); });

describe('API authentication', () => {
  it('rejects missing, malformed and forged tokens', async () => {
    expect((await s.call(null, 'GET', '/customers')).status).toBe(401);
    const forged = await fetch(`${s.base}/api/customers`, { headers: { authorization: 'Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.' } });
    expect(forged.status).toBe(401);
    const { SignJWT } = await import('jose');
    const wrongKey = await new SignJWT({ role: 'authenticated' }).setProtectedHeader({ alg: 'HS256' }).setSubject('00000000-0000-4000-8000-000000000001')
      .setAudience('authenticated').setExpirationTime('1h').sign(new TextEncoder().encode('not-the-server-secret-not-the-server-secret'));
    expect((await fetch(`${s.base}/api/customers`, { headers: { authorization: `Bearer ${wrongKey}` } })).status).toBe(401);
  });

  it('sends security headers', async () => {
    const r = await fetch(`${s.base}/health`);
    expect(r.headers.get('x-content-type-options')).toBe('nosniff');
    expect(r.headers.get('strict-transport-security')).toBeTruthy();
  });
});

describe('Role permissions through the API', () => {
  it('site engineers cannot see sales data', async () => {
    expect((await s.call('site', 'GET', '/customers')).data).toEqual([]);
    expect((await s.call('site', 'GET', `/customers/${CUSTOMER}`)).status).toBe(404);
    expect((await s.call('site', 'GET', `/opportunities/${OPP}`)).status).toBe(404);
    expect((await s.call('site', 'GET', '/quotations')).data).toEqual([]);
    expect((await s.call('site', 'POST', '/customers', { name_en: 'Sneaky' })).status).toBe(403);
    expect((await s.call('site', 'GET', '/dashboard')).status).toBe(403);
  });

  it('read-only roles cannot change records', async () => {
    expect((await s.call('pm', 'GET', `/customers/${CUSTOMER}`)).status).toBe(200);
    expect((await s.call('pm', 'PATCH', `/customers/${CUSTOMER}`, { name_en: 'Changed' })).status).toBe(403);
    expect((await s.call('pm', 'PATCH', `/opportunities/${OPP}`, { title: 'Changed' })).status).toBe(403);
    expect((await s.call('finance', 'POST', '/quotations', { opportunity_id: OPP, title: 'x' })).status).toBe(403);
    expect((await s.call('finance', 'POST', '/boq-templates', { name: 'x' })).status).toBe(403);
    expect((await s.call('sales', 'POST', '/boq-templates', { name: 'x' })).status).toBe(403);
  });

  it('administration is restricted', async () => {
    expect((await s.call('gm', 'GET', '/admin/users')).status).toBe(403);
    expect((await s.call('sales', 'PATCH', '/admin/settings', { allow_self_approval: true })).status).toBe(403);
    expect((await s.call('admin', 'GET', '/admin/users')).status).toBe(200);
  });

  it('users cannot reactivate or promote themselves', async () => {
    const me = (await s.call('sales', 'GET', '/me')).data;
    expect(me.permissions).toContain('quotations.submit');
    expect(me.permissions).not.toContain('quotations.approve');
    expect((await s.call('sales', 'PUT', `/admin/users/${me.id}/roles`, { roles: ['administrator'] })).status).toBe(403);
    expect((await s.call('sales', 'PATCH', '/me', { full_name: 'Sara S.' })).status).toBe(200);
  });

  it('deactivated users lose all access immediately', async () => {
    const fin = (await s.call('finance', 'GET', '/me')).data;
    expect((await s.call('admin', 'PATCH', `/admin/users/${fin.id}`, { is_active: false })).status).toBe(200);
    expect((await s.call('finance', 'GET', '/me')).status).toBe(403);
    expect((await s.call('finance', 'GET', '/customers')).data).toEqual([]);
    expect((await s.call('admin', 'PATCH', `/admin/users/${fin.id}`, { is_active: true })).status).toBe(200);
    expect((await s.call('finance', 'GET', '/customers')).data.length).toBeGreaterThan(0);
  });

  it('the last administrator cannot be removed', async () => {
    const admin = (await s.call('admin', 'GET', '/me')).data;
    const r = await s.call('admin', 'PUT', `/admin/users/${admin.id}/roles`, { roles: ['sales'] });
    expect(r.status).toBe(422);
    expect((await s.call('admin', 'GET', '/me')).data.permissions).toContain('users.manage');
  });
});

describe('Database-level protection (bypassing the API)', () => {
  // Each attempt runs in a savepoint so one rejected statement does not abort the rest of the transaction.
  let sp = 0;
  const attempt = async (sql: string, params: unknown[] = []) => {
    const name = `sp${++sp}`;
    await c.query(`savepoint ${name}`);
    try {
      return await c.query(sql, params);
    } catch (e) {
      await c.query(`rollback to savepoint ${name}`);
      throw e;
    }
  };
  const DENIED = /permission denied|row-level security|cannot|append-only|calculated|not permitted/i;
  const expectDenied = (sql: string, params: unknown[] = []) => expect(attempt(sql, params)).rejects.toThrow(DENIED);

  it('anonymous connections can read nothing', async () => {
    await asUser(c, null, () => expectDenied('select * from public.customers'), 'anon');
    await asUser(c, null, () => expectDenied('select public.has_permission($1)', ['customers.read']), 'anon');
  });

  it('row-level security hides and protects records', async () => {
    await asUser(c, USERS.site, async () => {
      expect((await c.query('select * from public.customers')).rowCount).toBe(0);
      expect((await attempt(`update public.customers set name_en = 'x'`)).rowCount).toBe(0);
    });
    await asUser(c, USERS.pm, async () => {
      expect((await c.query('select * from public.customers')).rowCount).toBeGreaterThan(0);
      expect((await attempt(`update public.customers set name_en = 'x'`)).rowCount).toBe(0);
      await expectDenied(`insert into public.customers (name_en) values ('x')`);
    });
  });

  it('numbering counters and audit log cannot be tampered with', async () => {
    await asUser(c, USERS.admin, async () => {
      await expectDenied(`update public.document_sequences set last_value = 0`);
      await expectDenied(`select public.next_document_number('quotation', 'QTN')`);
    });
    await asUser(c, USERS.admin, () => expectDenied(`delete from public.audit_events`));
    await asUser(c, USERS.admin, () => expectDenied(`insert into public.audit_events (table_name, action) values ('x', 'EVENT')`));
    // Even the table owner cannot rewrite history.
    await expect(c.query('delete from public.audit_events where id = (select min(id) from public.audit_events)')).rejects.toThrow(/append-only/);
  });

  it('calculated prices cannot be written directly', async () => {
    await asUser(c, USERS.estimator, async () => {
      const q = await c.query(`select public.create_quotation($1, 'Direct write test') as id`, [OPP]);
      const rev = (await c.query('select id from public.quotation_revisions where quotation_id = $1', [q.rows[0].id])).rows[0].id;
      await c.query(`insert into public.quotation_lines (revision_id, description_en, quantity, material_unit_cost, sell_rate, sell_total) values ($1, 'x', 2, 100, 99999, 99999)`, [rev]);
      const line = (await c.query('select * from public.quotation_lines where revision_id = $1', [rev])).rows[0];
      expect(line.sell_total).not.toBe('99999.00');
      await expectDenied('update public.quotation_lines set sell_rate = 1 where id = $1', [line.id]);
      await expectDenied('update public.quotation_revisions set total_amount = 1 where id = $1', [rev]);
      // Status cannot jump straight to approved or awarded.
      await expect(attempt(`update public.quotation_revisions set status = 'approved' where id = $1`, [rev])).rejects.toThrow(/Invalid quotation status change/);
      await expect(attempt(`update public.quotations set status = 'won' where id = $1`, [q.rows[0].id])).rejects.toThrow(/award_quotation/);
      await expectDenied(`select public.award_quotation($1, 'x', $2, current_date, current_date)`, [rev, '00000000-0000-4000-8000-000000000005']);
    });
  });

  it('opportunities can only be won by awarding a quotation', async () => {
    await asUser(c, USERS.admin, async () => {
      await expect(attempt(`update public.opportunities set stage = 'won' where id = $1`, [OPP])).rejects.toThrow(/awarding a quotation/);
      await expect(attempt(`insert into public.opportunities (title, stage, customer_id) values ('x', 'won', $1)`, [CUSTOMER])).rejects.toThrow(/awarding a quotation/);
    });
  });
});
