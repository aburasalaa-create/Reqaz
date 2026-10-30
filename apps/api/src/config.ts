import { z } from 'zod';

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().default(8787),
  HOST: z.string().default('0.0.0.0'),
  DATABASE_URL: z.string().min(1),
  DATABASE_POOL_MAX: z.coerce.number().default(10),
  // CORS: the web app origin, e.g. https://app.reqaz.com
  APP_ORIGIN: z.string().default('http://localhost:5173'),
  // Authentication. 'supabase' verifies Supabase Auth access tokens; 'dev' issues local tokens
  // for seeded users and is refused when NODE_ENV=production.
  AUTH_MODE: z.enum(['supabase', 'dev']).default('supabase'),
  SUPABASE_URL: z.string().optional(),
  SUPABASE_JWT_SECRET: z.string().optional(),           // legacy HS256 projects
  SUPABASE_SERVICE_ROLE_KEY: z.string().optional(),     // server-only: storage + user invites
  // Public (publishable/anon) key, handed to the browser at /api/public-config. Falls back to VITE_SUPABASE_ANON_KEY.
  SUPABASE_ANON_KEY: z.string().optional(),
  DEV_JWT_SECRET: z.string().default('dev-only-secret-change-me-dev-only-secret'),
  // Private document storage
  STORAGE_DRIVER: z.enum(['local', 'supabase']).default('local'),
  STORAGE_LOCAL_DIR: z.string().default('./storage-local'),
  STORAGE_BUCKET: z.string().default('rms-documents'),
  MAX_UPLOAD_MB: z.coerce.number().default(25),
  // Keep uploaded files and archived copies of issued documents. Off by default in production so the app runs without a
  // storage bucket: issued documents stay reproducible from their frozen data and are generated when downloaded.
  FILE_STORAGE: z.enum(['on', 'off']).optional(),
  // Path to a Chromium binary for PDF rendering (optional; Playwright default otherwise)
  CHROMIUM_PATH: z.string().optional(),
  // Built web app (apps/web/dist) to serve from the same origin; empty when the web app is hosted separately.
  WEB_DIST: z.string().optional(),
  RATE_LIMIT_PER_MINUTE: z.coerce.number().default(600),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const cfg = schema.parse(env);
  cfg.SUPABASE_ANON_KEY ??= env.VITE_SUPABASE_ANON_KEY || undefined;
  if (cfg.SUPABASE_ANON_KEY && isSecretKey(cfg.SUPABASE_ANON_KEY)) {
    throw new Error('SUPABASE_ANON_KEY holds a secret/service-role key; it must be the publishable (anon) key');
  }
  cfg.FILE_STORAGE ??= cfg.NODE_ENV === 'production' ? 'off' : 'on';
  if (cfg.NODE_ENV === 'production') {
    if (cfg.AUTH_MODE !== 'supabase') throw new Error('AUTH_MODE=dev is not allowed in production');
    if (!cfg.SUPABASE_URL) throw new Error('SUPABASE_URL is required in production');
    if (cfg.FILE_STORAGE === 'on' && cfg.STORAGE_DRIVER !== 'supabase') throw new Error('Use STORAGE_DRIVER=supabase in production');
  }
  return cfg;
}

/** True for keys that must never reach a browser: new-style secret keys and legacy service_role JWTs. */
export function isSecretKey(key: string): boolean {
  if (key.startsWith('sb_secret_')) return true;
  const payload = key.split('.')[1];
  if (!payload) return false;
  try {
    return JSON.parse(Buffer.from(payload, 'base64url').toString()).role === 'service_role';
  } catch {
    return false;
  }
}
