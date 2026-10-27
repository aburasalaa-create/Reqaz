import { createRemoteJWKSet, jwtVerify, SignJWT, type JWTPayload } from 'jose';
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
  if (cfg.SUPABASE_JWT_SECRET) {
    const key = new TextEncoder().encode(cfg.SUPABASE_JWT_SECRET);
    return async (token) => toUser((await jwtVerify(token, key, { audience: 'authenticated', algorithms: ['HS256'] })).payload);
  }
  if (!cfg.SUPABASE_URL) throw new Error('SUPABASE_URL or SUPABASE_JWT_SECRET is required');
  // Supabase projects with asymmetric signing keys publish them here.
  const jwks = createRemoteJWKSet(new URL('/auth/v1/.well-known/jwks.json', cfg.SUPABASE_URL));
  const issuer = new URL('/auth/v1', cfg.SUPABASE_URL).toString();
  return async (token) => toUser((await jwtVerify(token, jwks, { audience: 'authenticated', issuer })).payload);
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
