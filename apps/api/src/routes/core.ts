import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { many, one, type Db, inSequence } from '../db.js';
import { supabaseKeyHeaders } from '../storage.js';
import { HttpError } from '../errors.js';
import type { Config } from '../config.js';
import { idParam, optText, requirePermission, tx, updateOrFail } from './util.js';

export default async function coreRoutes(app: FastifyInstance, { db, cfg }: { db: Db; cfg: Config }) {
  app.get('/me', async (req) => tx(db, req, async (t) => {
    const user = await one(t, 'select * from public.app_users where id = auth.uid()');
    if (!user || !user.is_active) throw new HttpError(403, 'Your account is not active in RMS. Ask an administrator for access.', 'inactive');
    const permissions = (await many<{ p: string }>(t, 'select public.current_permissions() as p')).map((r) => r.p);
    const roles = await many(t, `select r.code, r.name_en, r.name_ar from public.user_roles ur join public.roles r on r.id = ur.role_id where ur.user_id = auth.uid()`);
    return { ...user, permissions, roles };
  }));

  app.patch('/me', async (req) => {
    const body = z.object({ full_name: z.string().trim().min(1).max(200).optional(), full_name_ar: optText, phone: optText, job_title: optText, locale: z.enum(['en', 'ar']).optional() }).parse(req.body);
    return tx(db, req, (t) => updateOrFail(t, 'app_users', req.user.id, body, 'User'));
  });

  app.get('/lookups', async (req) => tx(db, req, async (t) => ({
    currencies: await many(t, 'select * from public.currencies where is_active order by code'),
    vat_codes: await many(t, 'select * from public.vat_codes where is_active order by rate desc'),
    users: await many(t, 'select id, full_name, full_name_ar, email, phone, job_title from public.app_users where is_active order by full_name'),
    settings: await one(t, 'select * from public.company_settings'),
  })));

  app.get('/dashboard', async (req) => tx(db, req, async (t) => {
    await requirePermission(t, 'dashboard.read');
    const [pipeline, deadlines, overdue, approvals, recentWins, quoteStats] = await inSequence([
      () => many(t, `select stage, count(*)::int as count, coalesce(sum(expected_value), 0) as value,
                      coalesce(sum(expected_value * win_probability / 100.0), 0)::numeric(18,2) as weighted
               from public.opportunities where stage not in ('won', 'lost') group by stage`),
      () => many(t, `select t.id, t.number, t.title, t.submission_deadline, c.name_en as customer_name
               from public.tenders t join public.customers c on c.id = t.customer_id
               where t.status in ('received', 'under_review', 'estimating') and t.submission_deadline >= now() - interval '1 day'
               order by t.submission_deadline limit 10`),
      () => many(t, `select f.id, f.subject, f.due_at, f.type, o.id as opportunity_id, o.number as opportunity_number, o.title as opportunity_title,
                      u.full_name as assigned_name
               from public.follow_ups f join public.opportunities o on o.id = f.opportunity_id
               left join public.app_users u on u.id = f.assigned_to
               where f.completed_at is null and f.due_at < now() order by f.due_at limit 20`),
      () => many(t, `select r.id as revision_id, r.revision_no, r.total_amount, r.submitted_for_approval_at, q.id as quotation_id, q.number, q.title, q.currency,
                      c.name_en as customer_name, u.full_name as submitted_by_name
               from public.quotation_revisions r join public.quotations q on q.id = r.quotation_id
               join public.customers c on c.id = q.customer_id left join public.app_users u on u.id = r.submitted_for_approval_by
               where r.status = 'pending_approval' order by r.submitted_for_approval_at`),
      () => many(t, `select o.id, o.number, o.title, o.stage_changed_at, ct.original_value, ct.currency
               from public.opportunities o left join public.contracts ct on ct.opportunity_id = o.id
               where o.stage = 'won' order by o.stage_changed_at desc limit 5`),
      () => one(t, `select count(*) filter (where stage = 'won' and stage_changed_at > now() - interval '365 days')::int as won_12m,
                     count(*) filter (where stage = 'lost' and stage_changed_at > now() - interval '365 days')::int as lost_12m
              from public.opportunities`),
    ]);
    return { pipeline, deadlines, overdue_follow_ups: overdue, pending_approvals: approvals, recent_wins: recentWins, stats: quoteStats };
  }));

  // Administration -------------------------------------------------------------
  app.get('/admin/users', async (req) => tx(db, req, async (t) => {
    await requirePermission(t, 'users.manage');
    return many(t, `select u.*, coalesce(array_agg(r.code order by r.code) filter (where r.code is not null), '{}') as roles
      from public.app_users u left join public.user_roles ur on ur.user_id = u.id left join public.roles r on r.id = ur.role_id
      group by u.id order by u.full_name`);
  }));

  app.get('/admin/roles', async (req) => tx(db, req, async (t) => many(t, `
    select r.*, coalesce(array_agg(rp.permission_code order by rp.permission_code) filter (where rp.permission_code is not null), '{}') as permissions
    from public.roles r left join public.role_permissions rp on rp.role_id = r.id group by r.id order by r.name_en`)));

  // Invite a user through Supabase Auth (service-role key stays on the server).
  app.post('/admin/users', async (req, reply) => {
    const body = z.object({ email: z.email(), full_name: z.string().trim().min(1).max(200), roles: z.array(z.string()).default([]) }).parse(req.body);
    const userId = await tx(db, req, async (t) => {
      await requirePermission(t, 'users.manage');
      return null as string | null;
    }).then(async () => {
      if (cfg.AUTH_MODE === 'dev') {
        // Development only: create the auth user directly.
        const r = await db.query('insert into auth.users (email, raw_user_meta_data) values ($1, $2) returning id', [body.email, { full_name: body.full_name }]);
        return r.rows[0].id as string;
      }
      if (!cfg.SUPABASE_URL || !cfg.SUPABASE_SERVICE_ROLE_KEY) throw new HttpError(501, 'User invitations need SUPABASE_SERVICE_ROLE_KEY', 'not_configured');
      // The invite email links back to RMS, where the new user chooses a password.
      const inviteUrl = new URL('/auth/v1/invite', cfg.SUPABASE_URL);
      inviteUrl.searchParams.set('redirect_to', `${cfg.APP_ORIGIN.split(',')[0].trim()}/set-password`);
      const res = await fetch(inviteUrl, {
        method: 'POST',
        headers: { ...supabaseKeyHeaders(cfg.SUPABASE_SERVICE_ROLE_KEY), 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: body.email, data: { full_name: body.full_name } }),
      });
      if (!res.ok) throw new HttpError(502, `Invitation failed: ${await res.text()}`, 'upstream');
      return (await res.json()).id as string;
    });
    const user = await tx(db, req, async (t) => {
      await t.query('update public.app_users set full_name = $2 where id = $1', [userId, body.full_name]);
      for (const code of body.roles) {
        await t.query('insert into public.user_roles (user_id, role_id, granted_by) select $1, id, auth.uid() from public.roles where code = $2 on conflict do nothing', [userId, code]);
      }
      return one(t, 'select * from public.app_users where id = $1', [userId]);
    });
    return reply.status(201).send(user);
  });

  app.put('/admin/users/:id/roles', async (req) => {
    const { id } = idParam.parse(req.params);
    const { roles } = z.object({ roles: z.array(z.string()).max(20) }).parse(req.body);
    return tx(db, req, async (t) => {
      await requirePermission(t, 'users.manage');
      // Grant first, then revoke, so an administrator editing their own roles keeps users.manage until the end.
      await t.query(`insert into public.user_roles (user_id, role_id, granted_by) select $1, id, auth.uid() from public.roles where code = any($2) on conflict do nothing`, [id, roles]);
      await t.query(`delete from public.user_roles where user_id = $1 and role_id not in (select id from public.roles where code = any($2))`, [id, roles]);
      return many(t, 'select r.code from public.user_roles ur join public.roles r on r.id = ur.role_id where ur.user_id = $1', [id]);
    });
  });

  app.patch('/admin/users/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({ is_active: z.boolean().optional(), full_name: z.string().trim().min(1).max(200).optional(), full_name_ar: optText, phone: optText, job_title: optText }).parse(req.body);
    return tx(db, req, async (t) => {
      await requirePermission(t, 'users.manage');
      return updateOrFail(t, 'app_users', id, body, 'User');
    });
  });

  app.patch('/admin/settings', async (req) => {
    const body = z.object({
      legal_name_en: z.string().trim().min(1).optional(), legal_name_ar: z.string().trim().min(1).optional(),
      vat_number: z.union([z.literal(''), z.string().regex(/^3\d{13}3$/)]).nullish().transform((v) => (v === undefined ? undefined : v || null)),
      cr_number: optText, address_en: optText, address_ar: optText, phone: optText, email: optText, website: optText,
      building_number: optText, street: optText, district: optText, city: optText, postal_code: optText, additional_number: optText,
      unified_number: optText,
      bank_accounts: z.array(z.object({
        bank_name: z.string().trim().min(1).max(100), account_name: z.string().trim().max(200).optional(),
        account_number: z.string().trim().max(40).optional(), iban: z.string().trim().toUpperCase().regex(/^SA\d{22}$/, 'IBAN must be SA followed by 22 digits'),
        show_on_invoices: z.boolean().default(true),
      }).strict()).max(10).optional().transform((v) => (v === undefined ? undefined : JSON.stringify(v))),
      invoice_terms_en: optText, invoice_terms_ar: optText,
      default_vat_rate: z.coerce.number().min(0).max(99).optional(),
      quotation_validity_days: z.coerce.number().int().min(1).max(365).optional(),
      allow_self_approval: z.boolean().optional(),
    }).parse(req.body);
    return tx(db, req, async (t) => {
      const cols = Object.keys(body).filter((k) => (body as any)[k] !== undefined);
      if (!cols.length) return one(t, 'select * from public.company_settings');
      const r = await t.query(`update public.company_settings set ${cols.map((c, i) => `"${c}" = $${i + 1}`).join(', ')} returning *`, cols.map((c) => (body as any)[c]));
      if (!r.rowCount) throw new HttpError(403, 'You do not have permission for this action', 'forbidden');
      return r.rows[0];
    });
  });

  app.get('/audit', async (req) => {
    const q = z.object({ table: z.string().max(64).optional(), record_id: z.string().max(64).optional(), limit: z.coerce.number().int().min(1).max(500).default(100) }).parse(req.query);
    return tx(db, req, async (t) => {
      await requirePermission(t, 'audit.read');
      return many(t, `select a.*, u.full_name as actor_name from public.audit_events a left join public.app_users u on u.id = a.actor_id
        where ($1::text is null or a.table_name = $1) and ($2::text is null or a.record_id = $2)
        order by a.id desc limit $3`, [q.table ?? null, q.record_id ?? null, q.limit]);
    });
  });
}
