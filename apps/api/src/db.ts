import pg from 'pg';

// Return numeric/decimal values as strings so money is never converted to floating point.
pg.types.setTypeParser(1700, (v) => v);
// Dates (no time) stay as 'YYYY-MM-DD'.
pg.types.setTypeParser(1082, (v) => v);
// bigint ids as numbers (audit ids, history ids are far below 2^53).
pg.types.setTypeParser(20, (v) => Number(v));

export type Db = pg.Pool;
export type Tx = pg.PoolClient;

export function createPool(url: string, max: number): Db {
  return new pg.Pool({ connectionString: url, max });
}

/**
 * Runs fn in a transaction as the Postgres `authenticated` role with the user's JWT claims,
 * exactly as Supabase PostgREST does. Row-level security and permission checks in the
 * database therefore apply to every query made through the API.
 */
export async function withUser<T>(db: Db, userId: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
  const client = await db.connect();
  try {
    await client.query('begin');
    await client.query('set local role authenticated');
    await client.query(`select set_config('request.jwt.claims', $1, true)`, [
      JSON.stringify({ sub: userId, role: 'authenticated' }),
    ]);
    const result = await fn(client);
    await client.query('commit');
    return result;
  } catch (e) {
    await client.query('rollback').catch(() => undefined);
    throw e;
  } finally {
    client.release();
  }
}

/** Privileged transaction for system tasks (never driven by user-supplied SQL). */
export async function withSystem<T>(db: Db, fn: (tx: Tx) => Promise<T>): Promise<T> {
  const client = await db.connect();
  try {
    await client.query('begin');
    const result = await fn(client);
    await client.query('commit');
    return result;
  } catch (e) {
    await client.query('rollback').catch(() => undefined);
    throw e;
  } finally {
    client.release();
  }
}

export async function one<T = any>(tx: Tx, sql: string, params: unknown[] = []): Promise<T | undefined> {
  const r = await tx.query(sql, params);
  return r.rows[0] as T | undefined;
}

export async function many<T = any>(tx: Tx, sql: string, params: unknown[] = []): Promise<T[]> {
  const r = await tx.query(sql, params);
  return r.rows as T[];
}

const ident = (s: string) => {
  if (!/^[a-z_][a-z0-9_]*$/.test(s)) throw new Error(`Unsafe identifier: ${s}`);
  return `"${s}"`;
};

/** INSERT with column names taken from validated object keys (never from raw input). */
export async function insertRow<T = any>(tx: Tx, table: string, data: Record<string, unknown>): Promise<T> {
  const cols = Object.keys(data).filter((k) => data[k] !== undefined);
  const sql = cols.length
    ? `insert into public.${ident(table)} (${cols.map(ident).join(', ')}) values (${cols.map((_, i) => `$${i + 1}`).join(', ')}) returning *`
    : `insert into public.${ident(table)} default values returning *`;
  const r = await tx.query(sql, cols.map((c) => data[c]));
  return r.rows[0] as T;
}

/** UPDATE by id; returns undefined when the row is missing or not visible to the user. */
export async function updateRow<T = any>(tx: Tx, table: string, id: string, data: Record<string, unknown>): Promise<T | undefined> {
  const cols = Object.keys(data).filter((k) => data[k] !== undefined);
  if (!cols.length) return one<T>(tx, `select * from public.${ident(table)} where id = $1`, [id]);
  const sql = `update public.${ident(table)} set ${cols.map((c, i) => `${ident(c)} = $${i + 2}`).join(', ')} where id = $1 returning *`;
  const r = await tx.query(sql, [id, ...cols.map((c) => data[c])]);
  return r.rows[0] as T | undefined;
}

/** Runs queries one after another: a transaction's client can only execute one query at a time. */
export async function inSequence<T extends readonly (() => Promise<unknown>)[]>(fns: T): Promise<{ [K in keyof T]: Awaited<ReturnType<T[K]>> }> {
  const out: unknown[] = [];
  for (const fn of fns) out.push(await fn());
  return out as { [K in keyof T]: Awaited<ReturnType<T[K]>> };
}
