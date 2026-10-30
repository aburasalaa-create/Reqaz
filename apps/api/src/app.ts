import { createHash } from 'node:crypto';
import Fastify from 'fastify';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import multipart from '@fastify/multipart';
import rateLimit from '@fastify/rate-limit';
import fastifyStatic from '@fastify/static';
import { resolve } from 'node:path';
import { z } from 'zod';
import type { Config } from './config.js';
import type { Db } from './db.js';
import { authHook, createVerifier, signDevToken, type TokenVerifier } from './auth.js';
import { errorHandler, HttpError } from './errors.js';
import type { Storage } from './storage.js';
import type { PdfRenderer } from './pdf/renderer.js';
import coreRoutes from './routes/core.js';
import partyRoutes from './routes/parties.js';
import crmRoutes from './routes/crm.js';
import quotationRoutes from './routes/quotations.js';
import templateRoutes from './routes/templates.js';
import attachmentRoutes from './routes/attachments.js';
import invoiceRoutes from './routes/invoices.js';
import procurementRoutes from './routes/procurement.js';
import expenseRoutes from './routes/expenses.js';

export interface AppDeps {
  cfg: Config;
  db: Db;
  storage: Storage;
  pdf: PdfRenderer;
  verifier?: TokenVerifier;
}

export async function buildApp({ cfg, db, storage, pdf, verifier }: AppDeps) {
  const app = Fastify({
    logger: cfg.NODE_ENV === 'test' ? false : { level: 'info', redact: ['req.headers.authorization'] },
    bodyLimit: 2 * 1024 * 1024,
    trustProxy: true,
  });
  app.setErrorHandler(errorHandler);
  await app.register(helmet, { contentSecurityPolicy: false });
  await app.register(cors, { origin: cfg.APP_ORIGIN.split(','), credentials: false, methods: ['GET', 'POST', 'PATCH', 'PUT', 'DELETE'] });
  // Counted per signed-in session, not per IP: a whole office often shares one public address.
  // Requests without a token (sign-in pages, health) are still counted per IP.
  await app.register(rateLimit, {
    max: cfg.RATE_LIMIT_PER_MINUTE, timeWindow: '1 minute',
    keyGenerator: (req) => {
      const auth = req.headers.authorization;
      return auth?.startsWith('Bearer ') ? `t:${createHash('sha256').update(auth).digest('base64url').slice(0, 22)}` : `ip:${req.ip}`;
    },
  });
  await app.register(multipart, { limits: { fileSize: cfg.MAX_UPLOAD_MB * 1024 * 1024, files: 1, fields: 10 } });

  app.get('/health', async () => {
    await db.query('select 1');
    return { ok: true };
  });

  const verify = verifier ?? createVerifier(cfg);

  await app.register(async (api) => {
    // Public values the browser needs to start Supabase sign-in; read at runtime so the web build needs no secrets or rebuilds.
    api.get('/public-config', async () => ({ supabaseUrl: cfg.SUPABASE_URL ?? null, supabaseAnonKey: cfg.SUPABASE_ANON_KEY ?? null }));

    // Local development sign-in for seeded users. Never registered in production.
    if (cfg.AUTH_MODE === 'dev' && cfg.NODE_ENV !== 'production') {
      api.get('/dev/users', async () => (await db.query(`
        select u.id, u.email, u.full_name, coalesce(array_agg(r.code) filter (where r.code is not null), '{}') as roles
        from public.app_users u left join public.user_roles ur on ur.user_id = u.id left join public.roles r on r.id = ur.role_id
        where u.is_active group by u.id order by u.full_name`)).rows);
      api.post('/dev/login', async (req) => {
        const { email } = z.object({ email: z.email() }).parse(req.body);
        const r = await db.query('select id, email from public.app_users where email = $1 and is_active', [email]);
        if (!r.rowCount) throw new HttpError(401, 'Unknown user', 'unauthorized');
        return { access_token: await signDevToken(cfg, r.rows[0].id, r.rows[0].email) };
      });
    }

    await api.register(async (secured) => {
      secured.addHook('onRequest', authHook(verify));
      await secured.register(coreRoutes, { db, cfg });
      await secured.register(partyRoutes, { db });
      await secured.register(crmRoutes, { db });
      await secured.register(quotationRoutes, { db, storage, pdf });
      await secured.register(templateRoutes, { db });
      await secured.register(attachmentRoutes, { db, storage });
      await secured.register(invoiceRoutes, { db, storage, pdf });
      await secured.register(procurementRoutes, { db, storage, pdf });
      await secured.register(expenseRoutes, { db });
    });
  }, { prefix: '/api' });

  // Single-container deployment: serve the built web app and let client-side routes fall back to index.html.
  if (cfg.WEB_DIST) {
    await app.register(fastifyStatic, { root: resolve(cfg.WEB_DIST), wildcard: false, maxAge: '1h' });
    app.setNotFoundHandler((req, reply) => {
      if (req.method !== 'GET' || req.url.startsWith('/api/') || /\.[a-z0-9]+(\?|$)/i.test(req.url)) return reply.status(404).send({ error: 'not_found', message: 'Not found' });
      return reply.header('Cache-Control', 'no-cache').sendFile('index.html');
    });
  }

  return app;
}
