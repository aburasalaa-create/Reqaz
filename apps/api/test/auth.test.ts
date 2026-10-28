// Supabase session verification: legacy HS256 secret and asymmetric signing keys are both accepted.
import { describe, expect, it } from 'vitest';
import { SignJWT } from 'jose';
import { createVerifier } from '../src/auth.js';
import { supabaseKeyHeaders } from '../src/storage.js';

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
