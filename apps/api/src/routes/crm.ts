import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { FOLLOW_UP_TYPES, LEAD_SOURCES, OPPORTUNITY_STAGES, TENDER_STATUSES } from '@rms/shared';
import { insertRow, many, type Db } from '../db.js';
import { HttpError, notFound } from '../errors.js';
import { decimal, getOr404, idParam, listQuery, optDate, optDateTime, optEmail, optText, optUuid, reqText, tx, updateOrFail } from './util.js';

const opportunityBody = z.object({
  title: reqText(300),
  customer_id: optUuid,
  prospect_company: optText,
  prospect_contact: optText,
  prospect_email: optEmail,
  prospect_phone: optText,
  source: z.enum(LEAD_SOURCES).optional(),
  stage: z.enum(OPPORTUNITY_STAGES).optional(),
  owner_id: optUuid,
  service_type: optText,
  location: optText,
  description: optText,
  expected_value: decimal.nullish(),
  currency: z.string().length(3).toUpperCase().optional(),
  win_probability: z.coerce.number().int().min(0).max(100).optional(),
  expected_close_date: optDate,
  lost_reason: optText,
});

const leadBody = z.object({
  source: z.enum(LEAD_SOURCES).default('manual'),
  contact_name: optText,
  company_name: optText,
  email: optEmail,
  phone: optText,
  service_interest: optText,
  message: optText,
});

const followUpBody = z.object({
  opportunity_id: z.uuid(),
  type: z.enum(FOLLOW_UP_TYPES).default('call'),
  subject: reqText(300),
  due_at: z.iso.datetime({ offset: true }),
  assigned_to: optUuid,
  outcome: optText,
});

const tenderBody = z.object({
  opportunity_id: z.uuid(),
  client_reference: optText,
  title: reqText(300),
  issue_date: optDate,
  clarification_deadline: optDateTime,
  site_visit_at: optDateTime,
  submission_deadline: z.iso.datetime({ offset: true }),
  bid_bond_required: z.boolean().optional(),
  bid_bond_amount: decimal.nullish(),
  status: z.enum(TENDER_STATUSES).optional(),
  notes: optText,
});

const OPP_LIST_SQL = `
  select o.*, c.name_en as customer_name, c.name_ar as customer_name_ar,
         u.full_name as owner_name,
         (select min(f.due_at) from public.follow_ups f where f.opportunity_id = o.id and f.completed_at is null) as next_follow_up_at,
         (select min(t.submission_deadline) from public.tenders t where t.opportunity_id = o.id
            and t.status in ('received', 'under_review', 'estimating')) as next_tender_deadline
  from public.opportunities o
  left join public.customers c on c.id = o.customer_id
  left join public.app_users u on u.id = o.owner_id`;

export default async function crmRoutes(app: FastifyInstance, { db }: { db: Db }) {
  // Opportunities -----------------------------------------------------------
  app.get('/opportunities', async (req) => {
    const q = listQuery.extend({
      stage: z.enum(OPPORTUNITY_STAGES).optional(),
      customer_id: z.uuid().optional(),
      owner_id: z.uuid().optional(),
      // Kanban hides deals closed more than 90 days ago unless asked.
      include_closed: z.enum(['true', 'false']).default('false'),
    }).parse(req.query);
    return tx(db, req, (t) => many(t, `${OPP_LIST_SQL}
      where ($1::text is null or o.title ilike '%' || $1 || '%' or o.number ilike '%' || $1 || '%'
             or c.name_en ilike '%' || $1 || '%' or o.prospect_company ilike '%' || $1 || '%')
        and ($2::public.opportunity_stage is null or o.stage = $2)
        and ($3::uuid is null or o.customer_id = $3)
        and ($4::uuid is null or o.owner_id = $4)
        and ($5 or o.stage not in ('won', 'lost') or o.stage_changed_at > now() - interval '90 days')
      order by o.stage_changed_at desc limit $6 offset $7`,
      [q.q || null, q.stage ?? null, q.customer_id ?? null, q.owner_id ?? null, q.include_closed === 'true', q.limit, q.offset]));
  });

  app.post('/opportunities', async (req, reply) => {
    const body = opportunityBody.parse(req.body);
    const row = await tx(db, req, (t) => insertRow(t, 'opportunities', body));
    return reply.status(201).send(row);
  });

  app.get('/opportunities/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const opp = await getOr404(t, `${OPP_LIST_SQL} where o.id = $1`, [id], 'Opportunity');
      const follow_ups = await many(t, `select f.*, u.full_name as assigned_name from public.follow_ups f
        left join public.app_users u on u.id = f.assigned_to where f.opportunity_id = $1 order by f.completed_at nulls first, f.due_at`, [id]);
      const tenders = await many(t, 'select * from public.tenders where opportunity_id = $1 order by created_at', [id]);
      const quotations = await many(t, `select q.*, r.revision_no, r.status as revision_status, r.total_amount, r.id as revision_id
        from public.quotations q
        left join lateral (select * from public.quotation_revisions r where r.quotation_id = q.id order by revision_no desc limit 1) r on true
        where q.opportunity_id = $1 order by q.created_at`, [id]);
      const history = await many(t, `select h.*, u.full_name as changed_by_name from public.opportunity_stage_history h
        left join public.app_users u on u.id = h.changed_by where h.opportunity_id = $1 order by h.changed_at`, [id]);
      return { ...opp, follow_ups, tenders, quotations, history };
    });
  });

  app.patch('/opportunities/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = opportunityBody.partial().parse(req.body);
    if (body.stage === 'won') throw new HttpError(422, 'Award a submitted quotation to mark the opportunity won', 'rule_violation');
    return tx(db, req, (t) => updateOrFail(t, 'opportunities', id, body, 'Opportunity'));
  });

  // Leads (inbound enquiries) ------------------------------------------------
  app.get('/leads', async (req) => {
    const q = listQuery.extend({ status: z.enum(['new', 'converted', 'rejected', 'spam']).optional() }).parse(req.query);
    return tx(db, req, (t) => many(t, `select * from public.leads
      where ($1::text is null or status = $1) order by received_at desc limit $2 offset $3`, [q.status ?? null, q.limit, q.offset]));
  });

  app.post('/leads', async (req, reply) => {
    const body = leadBody.parse(req.body);
    return reply.status(201).send(await tx(db, req, (t) => insertRow(t, 'leads', body)));
  });

  app.post('/leads/:id/convert', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({ customer_id: optUuid, title: z.string().trim().max(300).optional() }).parse(req.body ?? {});
    return tx(db, req, async (t) => {
      const lead = await getOr404<any>(t, 'select * from public.leads where id = $1 for update', [id], 'Lead');
      if (lead.status !== 'new') throw new HttpError(422, `Lead is already ${lead.status}`, 'rule_violation');
      const opp = await insertRow<any>(t, 'opportunities', {
        title: body.title || lead.service_interest || `Enquiry from ${lead.company_name || lead.contact_name || 'website'}`,
        customer_id: body.customer_id,
        prospect_company: lead.company_name,
        prospect_contact: lead.contact_name,
        prospect_email: lead.email,
        prospect_phone: lead.phone,
        source: lead.source,
        service_type: lead.service_interest,
        description: lead.message,
      });
      await t.query(`update public.leads set status = 'converted', opportunity_id = $2 where id = $1`, [id, opp.id]);
      return opp;
    });
  });

  app.post('/leads/:id/reject', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = z.object({ spam: z.boolean().default(false) }).parse(req.body ?? {});
    return tx(db, req, (t) => updateOrFail(t, 'leads', id, { status: body.spam ? 'spam' : 'rejected' }, 'Lead'));
  });

  // Follow-ups --------------------------------------------------------------
  app.get('/follow-ups', async (req) => {
    const q = z.object({ open: z.enum(['true', 'false']).default('true'), mine: z.enum(['true', 'false']).default('false') }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select f.*, o.number as opportunity_number, o.title as opportunity_title, u.full_name as assigned_name
      from public.follow_ups f join public.opportunities o on o.id = f.opportunity_id
      left join public.app_users u on u.id = f.assigned_to
      where (not $1 or f.completed_at is null) and (not $2 or f.assigned_to = auth.uid())
      order by f.due_at limit 500`, [q.open === 'true', q.mine === 'true']));
  });

  app.post('/follow-ups', async (req, reply) => {
    const body = followUpBody.parse(req.body);
    return reply.status(201).send(await tx(db, req, (t) => insertRow(t, 'follow_ups', body)));
  });

  app.patch('/follow-ups/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = followUpBody.omit({ opportunity_id: true }).partial()
      .extend({ completed: z.boolean().optional() }).parse(req.body);
    const { completed, ...rest } = body;
    const data: Record<string, unknown> = { ...rest };
    if (completed !== undefined) data.completed_at = completed ? new Date().toISOString() : null;
    return tx(db, req, (t) => updateOrFail(t, 'follow_ups', id, data, 'Follow-up'));
  });

  app.delete('/follow-ups/:id', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    await tx(db, req, async (t) => {
      const r = await t.query('delete from public.follow_ups where id = $1', [id]);
      if (!r.rowCount) throw notFound('Follow-up');
    });
    return reply.status(204).send();
  });

  // Tenders -----------------------------------------------------------------
  app.get('/tenders', async (req) => {
    const q = listQuery.extend({ status: z.enum(TENDER_STATUSES).optional(), upcoming: z.enum(['true', 'false']).default('false') }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select t.*, c.name_en as customer_name, c.name_ar as customer_name_ar, o.number as opportunity_number
      from public.tenders t join public.customers c on c.id = t.customer_id
      join public.opportunities o on o.id = t.opportunity_id
      where ($1::text is null or t.title ilike '%' || $1 || '%' or t.number ilike '%' || $1 || '%' or t.client_reference ilike '%' || $1 || '%')
        and ($2::public.tender_status is null or t.status = $2)
        and (not $3 or (t.submission_deadline >= now() and t.status in ('received', 'under_review', 'estimating')))
      order by t.submission_deadline limit $4 offset $5`, [q.q || null, q.status ?? null, q.upcoming === 'true', q.limit, q.offset]));
  });

  app.post('/tenders', async (req, reply) => {
    const body = tenderBody.parse(req.body);
    const row = await tx(db, req, async (t) => {
      const tender = await insertRow(t, 'tenders', body);
      // Receiving a tender moves the pipeline forward when the user may edit the opportunity.
      await t.query(`update public.opportunities set stage = 'tender_received'
                     where id = $1 and stage in ('new_lead', 'qualified') and public.has_permission('crm.write')`, [body.opportunity_id]);
      return tender;
    });
    return reply.status(201).send(row);
  });

  app.get('/tenders/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const tender = await getOr404(t, `select t.*, c.name_en as customer_name, o.number as opportunity_number, o.title as opportunity_title
        from public.tenders t join public.customers c on c.id = t.customer_id join public.opportunities o on o.id = t.opportunity_id
        where t.id = $1`, [id], 'Tender');
      const quotations = await many(t, 'select id, number, title, status from public.quotations where tender_id = $1', [id]);
      return { ...tender, quotations };
    });
  });

  app.patch('/tenders/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = tenderBody.partial().parse(req.body);
    return tx(db, req, (t) => updateOrFail(t, 'tenders', id, body, 'Tender'));
  });

}
