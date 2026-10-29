// Supabase session verification: legacy HS256 secret and asymmetric signing keys are both accepted.
import { describe, expect, it } from 'vitest';
import { SignJWT } from 'jose';
import { createVerifier } from '../src/auth.js';
import { supabaseKeyHeaders } from '../src/storage.js';
import { isSecretKey, loadConfig } from '../src/config.js';
import { buildApp } from '../src/app.js';

const cfg = { AUTH_MODE: 'supabase', SUPABASE_URL: 'https://example.supabase.co', SUPABASE_JWT_SECRET: 'test-secret-test-secret-test-secret!!' } as any;
const sign = (claims: Record<string, unknown>, secret = cfg.SUPABASE_JWT_SECRET, iss = 'https://example.supabase.co/auth/v1') =>
  new SignJWT(claims).setProtectedHeader({ alg: 'HS256' }).setSubject('00000000-0000-4000-8000-000000000001')
    .setAudience('authenticated').setIssuer(iss).setExpirationTime('5m').sign(new TextEncoder().encode(secret));

describe('Supabase token verification', () => {
  it('accepts a valid HS256 session token', async () => {
    const user = await createVerifier(cfg)(await sign({ role: 'authenticated', email: 'a@reqaz.com' }));
    expect(user).toEqual({ id: '00000000-0000-4000-8000-000000000001', email: 'a@reqaz.com' });
  });
  it('rejects a wrong secret, a wrong issuer, the anon role and garbage', async () => {
    const verify = createVerifier(cfg);
    await expect(verify(await sign({ role: 'authenticated' }, 'another-secret-another-secret-another'))).rejects.toThrow();
    await expect(verify(await sign({ role: 'authenticated' }, undefined, 'https://evil.example/auth/v1'))).rejects.toThrow();
    await expect(verify(await sign({ role: 'anon' }))).rejects.toThrow();
    await expect(verify('not-a-jwt')).rejects.toThrow();
  });
  it('rejects HS256 tokens when no shared secret is configured', async () => {
    const verify = createVerifier({ ...cfg, SUPABASE_JWT_SECRET: undefined });
    await expect(verify(await sign({ role: 'authenticated' }))).rejects.toThrow();
  });
});

describe('Supabase server key headers', () => {
  it('sends new secret keys as apikey only and legacy JWT keys as both', () => {
    expect(supabaseKeyHeaders('sb_secret_abc')).toEqual({ apikey: 'sb_secret_abc' });
    expect(supabaseKeyHeaders('eyJabc')).toEqual({ apikey: 'eyJabc', Authorization: 'Bearer eyJabc' });
  });
});

describe('public sign-in settings for the browser', () => {
  const env = { NODE_ENV: 'test', DATABASE_URL: 'postgres://unused', SUPABASE_URL: 'https://example.supabase.co' };
  const fakeJwt = (role: string) => `x.${Buffer.from(JSON.stringify({ role })).toString('base64url')}.y`;

  it('serves the URL and publishable key, falling back to VITE_SUPABASE_ANON_KEY', async () => {
    const cfg = loadConfig({ ...env, VITE_SUPABASE_ANON_KEY: 'sb_publishable_abc' } as NodeJS.ProcessEnv);
    const app = await buildApp({ cfg, db: {} as any, storage: {} as any, pdf: {} as any });
    const r = await app.inject({ method: 'GET', url: '/api/public-config' });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ supabaseUrl: 'https://example.supabase.co', supabaseAnonKey: 'sb_publishable_abc' });
    await app.close();
  });
  it('refuses to start with a secret or service-role key in the public slot', () => {
    expect(isSecretKey('sb_secret_abc')).toBe(true);
    expect(isSecretKey(fakeJwt('service_role'))).toBe(true);
    expect(isSecretKey(fakeJwt('anon'))).toBe(false);
    expect(isSecretKey('sb_publishable_abc')).toBe(false);
    expect(() => loadConfig({ ...env, SUPABASE_ANON_KEY: 'sb_secret_abc' } as NodeJS.ProcessEnv)).toThrow(/secret/);
  });
});
