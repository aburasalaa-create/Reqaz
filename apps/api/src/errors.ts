import type { FastifyError, FastifyReply, FastifyRequest } from 'fastify';
import { ZodError } from 'zod';

export class HttpError extends Error {
  constructor(public status: number, message: string, public code = 'error') {
    super(message);
  }
}
export const notFound = (what = 'Record') => new HttpError(404, `${what} not found`, 'not_found');
export const forbidden = (msg = 'You do not have permission for this action') => new HttpError(403, msg, 'forbidden');

// PostgreSQL SQLSTATE → HTTP status. Messages raised by our own triggers are safe to show.
const PG_STATUS: Record<string, [number, string]> = {
  '42501': [403, 'forbidden'],          // insufficient_privilege (RLS / our guards)
  '23514': [422, 'rule_violation'],     // check_violation (business rules)
  '23505': [409, 'duplicate'],          // unique_violation
  '23503': [422, 'invalid_reference'],  // foreign_key_violation
  '23502': [422, 'missing_value'],      // not_null_violation
  '22P02': [400, 'invalid_value'],      // invalid_text_representation (bad uuid/enum)
  '22003': [422, 'out_of_range'],
  '22007': [400, 'invalid_value'],
  '22008': [400, 'invalid_value'],
  'P0002': [404, 'not_found'],          // no_data_found
};

export function errorHandler(err: FastifyError & { code?: string; detail?: string }, req: FastifyRequest, reply: FastifyReply) {
  if (err instanceof HttpError) {
    return reply.status(err.status).send({ error: err.code, message: err.message });
  }
  if (err instanceof ZodError) {
    return reply.status(400).send({ error: 'validation', message: 'Invalid input', issues: err.issues });
  }
  if (err.code && PG_STATUS[err.code]) {
    const [status, code] = PG_STATUS[err.code];
    let message = err.message;
    if (err.code === '42501' && /row-level security/.test(message)) message = 'You do not have permission for this action';
    if (err.code === '23505') message = 'A record with the same unique value already exists';
    return reply.status(status).send({ error: code, message });
  }
  if (err.statusCode && err.statusCode < 500) {
    return reply.status(err.statusCode).send({ error: err.code ?? 'error', message: err.message });
  }
  req.log.error(err); if (process.env.DEBUG_ERRORS) console.error(err);
  return reply.status(500).send({ error: 'internal', message: 'Unexpected server error' });
}
