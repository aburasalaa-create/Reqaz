import { createRemoteJWKSet, decodeProtectedHeader, jwtVerify, SignJWT, type JWTPayload } from 'jose';
import type { FastifyReply, FastifyRequest } from 'fastify';
import type { Config } from './config.js';
import { HttpError } from './errors.js';

export interface AuthUser {
  id: string;
  email?: string;
}

declare module 'fastify' {
  interface FastifyRequest {
    user: AuthUser;
  }
}

export type TokenVerifier = (token: string) => Promise<AuthUser>;

export function createVerifier(cfg: Config): TokenVerifier {
  if (cfg.AUTH_MODE === 'dev') {
    const key = new TextEncoder().encode(cfg.DEV_JWT_SECRET);
    return async (token) => toUser((await jwtVerify(token, key, { audience: 'authenticated', algorithms: ['HS256'] })).payload);
  }
  if (!cfg.SUPABASE_URL && !cfg.SUPABASE_JWT_SECRET) throw new Error('SUPABASE_URL or SUPABASE_JWT_SECRET is required');
  // Legacy projects sign sessions with a shared HS256 secret; newer ones with asymmetric keys published as JWKS.
  // Both are accepted, chosen by the token's own algorithm, so rotating a project to signing keys needs no redeploy.
  const secret = cfg.SUPABASE_JWT_SECRET ? new TextEncoder().encode(cfg.SUPABASE_JWT_SECRET) : null;
  const jwks = cfg.SUPABASE_URL ? createRemoteJWKSet(new URL('/auth/v1/.well-known/jwks.json', cfg.SUPABASE_URL)) : null;
  const issuer = cfg.SUPABASE_URL ? new URL('/auth/v1', cfg.SUPABASE_URL).toString() : undefined;
  return async (token) => {
    let alg: string | undefined;
    try { alg = decodeProtectedHeader(token).alg; } catch { throw new HttpError(401, 'Invalid session', 'unauthorized'); }
    if (alg === 'HS256') {
      if (!secret) throw new HttpError(401, 'Invalid session', 'unauthorized');
      return toUser((await jwtVerify(token, secret, { audience: 'authenticated', algorithms: ['HS256'], issuer })).payload);
    }
    if (!jwks) throw new HttpError(401, 'Invalid session', 'unauthorized');
    return toUser((await jwtVerify(token, jwks, { audience: 'authenticated', issuer })).payload);
  };
}

function toUser(p: JWTPayload): AuthUser {
  if (!p.sub || p.role !== 'authenticated') throw new HttpError(401, 'Invalid session', 'unauthorized');
  return { id: p.sub, email: typeof p.email === 'string' ? p.email : undefined };
}

export async function signDevToken(cfg: Config, userId: string, email: string): Promise<string> {
  if (cfg.AUTH_MODE !== 'dev' || cfg.NODE_ENV === 'production') throw new HttpError(404, 'Not found', 'not_found');
  return new SignJWT({ role: 'authenticated', email })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(userId)
    .setAudience('authenticated')
    .setIssuedAt()
    .setExpirationTime('8h')
    .sign(new TextEncoder().encode(cfg.DEV_JWT_SECRET));
}

export function authHook(verify: TokenVerifier) {
  return async (req: FastifyRequest, _reply: FastifyReply) => {
    const header = req.headers.authorization;
    if (!header?.startsWith('Bearer ')) throw new HttpError(401, 'Sign in required', 'unauthorized');
    try {
      req.user = await verify(header.slice(7));
    } catch (e) {
      if (e instanceof HttpError) throw e;
      throw new HttpError(401, 'Session expired or invalid', 'unauthorized');
    }
  };
}
