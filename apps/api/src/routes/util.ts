import { z } from 'zod';
import type { FastifyRequest } from 'fastify';
import { one, updateRow, withUser, type Db, type Tx } from '../db.js';
import { forbidden, notFound } from '../errors.js';

export const idParam = z.object({ id: z.uuid() });
export const decimal = z.union([z.number().finite(), z.string().trim().regex(/^-?\d+(\.\d+)?$/)]).transform(String);
export const optText = z.string().trim().max(5000).nullish().transform((v) => (v === '' ? null : v));
export const reqText = (max = 300) => z.string().trim().min(1).max(max);
// Optional fields: omitted → undefined (left unchanged on update); '' or null → null (cleared).
const blankToNull = <T>(v: T | '' | null | undefined) => (v === undefined ? undefined : v === '' || v === null ? null : v);
export const optEmail = z.union([z.literal(''), z.email()]).nullish().transform(blankToNull);
export const optDate = z.union([z.literal(''), z.iso.date()]).nullish().transform(blankToNull);
export const optDateTime = z.union([z.literal(''), z.iso.datetime({ offset: true })]).nullish().transform(blankToNull);
export const optUuid = z.union([z.literal(''), z.uuid()]).nullish().transform(blankToNull);

export const listQuery = z.object({
  q: z.string().trim().max(200).optional(),
  limit: z.coerce.number().int().min(1).max(500).default(100),
  offset: z.coerce.number().int().min(0).default(0),
});

/** Run a handler in the caller's RLS-scoped transaction. */
export const tx = <T>(db: Db, req: FastifyRequest, fn: (t: Tx) => Promise<T>) => withUser(db, req.user.id, fn);

/**
 * Update a row; when nothing is updated, distinguish "not visible" (404) from
 * "visible but not writable under RLS" (403).
 */
export async function updateOrFail<T = any>(t: Tx, table: string, id: string, data: Record<string, unknown>, what: string): Promise<T> {
  const row = await updateRow<T>(t, table, id, data);
  if (row) return row;
  const visible = await one(t, `select 1 from public."${table}" where id = $1`, [id]);
  throw visible ? forbidden() : notFound(what);
}

export async function getOr404<T = any>(t: Tx, sql: string, params: unknown[], what: string): Promise<T> {
  const row = await one<T>(t, sql, params);
  if (!row) throw notFound(what);
  return row;
}

export async function requirePermission(t: Tx, code: string) {
  const r = await one<{ ok: boolean }>(t, 'select public.has_permission($1) as ok', [code]);
  if (!r?.ok) throw forbidden();
}
