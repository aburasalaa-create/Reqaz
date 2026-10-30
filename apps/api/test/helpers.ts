import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import type { AddressInfo } from 'node:net';
import pg from 'pg';
import { buildApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';
import { createPool } from '../src/db.js';
import { createStorage } from '../src/storage.js';
import { createPdfRenderer } from '../src/pdf/renderer.js';

const PG = `postgres://postgres@${process.env.PGHOST ?? 'localhost'}:${process.env.PGPORT ?? '54322'}`;
export const DATABASE_URL = `${PG}/${process.env.TEST_DB_NAME ?? 'rms_test'}`;

export const USERS = {
  admin: 'admin@reqaz.test',
  gm: 'gm@reqaz.test',
  sales: 'sales@reqaz.test',
  estimator: 'estimator@reqaz.test',
  pm: 'pm@reqaz.test',
  site: 'site@reqaz.test',
  finance: 'finance@reqaz.test',
  procurement: 'procurement@reqaz.test',
} as const;
export type Who = keyof typeof USERS;

export async function startServer() {
  const cfg = loadConfig({
    NODE_ENV: 'test', DATABASE_URL, AUTH_MODE: 'dev', STORAGE_DRIVER: 'local',
    STORAGE_LOCAL_DIR: mkdtempSync(path.join(tmpdir(), 'rms-storage-')), RATE_LIMIT_PER_MINUTE: '100000',
  } as NodeJS.ProcessEnv);
  const db = createPool(cfg.DATABASE_URL, 10);
  const pdf = createPdfRenderer(process.env.CHROMIUM_PATH);
  const app = await buildApp({ cfg, db, storage: createStorage(cfg), pdf });
  await app.listen({ port: 0, host: '127.0.0.1' });
  const base = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`;
  const tokens: Partial<Record<Who, string>> = {};

  async function token(who: Who) {
    if (!tokens[who]) {
      const r = await fetch(`${base}/api/dev/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: USERS[who] }) });
      tokens[who] = (await r.json()).access_token;
    }
    return tokens[who]!;
  }

  /** Call the API as a seeded user. Returns status and parsed JSON (or raw bytes). */
  async function call(who: Who | null, method: string, url: string, body?: unknown) {
    const headers: Record<string, string> = {};
    if (who) headers.authorization = `Bearer ${await token(who)}`;
    let payload: BodyInit | undefined;
    if (body instanceof FormData) payload = body;
    else if (body !== undefined) { headers['content-type'] = 'application/json'; payload = JSON.stringify(body); }
    const res = await fetch(`${base}/api${url}`, { method, headers, body: payload });
    const type = res.headers.get('content-type') ?? '';
    const data = type.includes('json') ? await res.json() : type ? Buffer.from(await res.arrayBuffer()) : null;
    return { status: res.status, data: data as any, headers: res.headers };
  }

  return {
    base, call, token,
    async close() { await app.close(); await pdf.close(); await db.end(); },
  };
}

/** Direct database client for low-level RLS / constraint checks. */
export async function dbClient() {
  const c = new pg.Client({ connectionString: DATABASE_URL });
  await c.connect();
  return c;
}

/** Run SQL as the `authenticated` role with the given user's claims, rolling back afterwards. */
export async function asUser<T>(c: pg.Client, email: string | null, fn: () => Promise<T>, role = 'authenticated'): Promise<T> {
  await c.query('begin');
  try {
    if (email) {
      const u = await c.query('select id from public.app_users where email = $1', [email]);
      await c.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: u.rows[0].id, role: 'authenticated' })]);
    }
    await c.query(`set local role ${role}`);
    return await fn();
  } finally {
    await c.query('rollback');
  }
}

export const userId = async (c: pg.Client, who: Who) =>
  (await c.query('select id from public.app_users where email = $1', [USERS[who]])).rows[0].id as string;
