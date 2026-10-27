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
  DEV_JWT_SECRET: z.string().default('dev-only-secret-change-me-dev-only-secret'),
  // Private document storage
  STORAGE_DRIVER: z.enum(['local', 'supabase']).default('local'),
  STORAGE_LOCAL_DIR: z.string().default('./storage-local'),
  STORAGE_BUCKET: z.string().default('rms-documents'),
  MAX_UPLOAD_MB: z.coerce.number().default(25),
  // Path to a Chromium binary for PDF rendering (optional; Playwright default otherwise)
  CHROMIUM_PATH: z.string().optional(),
  // Built web app (apps/web/dist) to serve from the same origin; empty when the web app is hosted separately.
  WEB_DIST: z.string().optional(),
  RATE_LIMIT_PER_MINUTE: z.coerce.number().default(300),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const cfg = schema.parse(env);
  if (cfg.NODE_ENV === 'production') {
    if (cfg.AUTH_MODE !== 'supabase') throw new Error('AUTH_MODE=dev is not allowed in production');
    if (!cfg.SUPABASE_URL) throw new Error('SUPABASE_URL is required in production');
    if (cfg.STORAGE_DRIVER !== 'supabase') throw new Error('Use STORAGE_DRIVER=supabase in production');
  }
  return cfg;
}
