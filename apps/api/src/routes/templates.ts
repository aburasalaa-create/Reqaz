import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { insertRow, many, type Db } from '../db.js';
import { decimal, getOr404, idParam, optText, reqText, tx, updateOrFail } from './util.js';

const itemBody = z.object({
  sort_order: z.coerce.number().int().optional(),
  section: optText,
  item_code: optText,
  description_en: reqText(2000),
  description_ar: optText,
  unit: z.string().trim().min(1).max(20).default('LS'),
  quantity: decimal.default('1'),
  material_unit_cost: decimal.default('0'),
  labour_unit_cost: decimal.default('0'),
  equipment_unit_cost: decimal.default('0'),
  subcontract_unit_cost: decimal.default('0'),
  other_unit_cost: decimal.default('0'),
});

const boqBody = z.object({
  name: reqText(200),
  description: optText,
  is_active: z.boolean().optional(),
  items: z.array(itemBody).max(2000).optional(),
});

const qtBody = z.object({
  name: reqText(200),
  scope_en: optText, scope_ar: optText,
  exclusions_en: optText, exclusions_ar: optText,
  payment_terms_en: optText, payment_terms_ar: optText,
  completion_period_en: optText, completion_period_ar: optText,
  overhead_pct: decimal.optional(),
  contingency_pct: decimal.optional(),
  pricing_method: z.enum(['markup', 'margin']).optional(),
  markup_pct: decimal.optional(),
  target_margin_pct: decimal.optional(),
  is_active: z.boolean().optional(),
});

export default async function templateRoutes(app: FastifyInstance, { db }: { db: Db }) {
  app.get('/boq-templates', async (req) => tx(db, req, (t) => many(t, `
    select b.*, (select count(*) from public.boq_template_items i where i.template_id = b.id)::int as item_count
    from public.boq_templates b order by b.name`)));

  app.get('/boq-templates/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => ({
      ...(await getOr404(t, 'select * from public.boq_templates where id = $1', [id], 'BOQ template')),
      items: await many(t, 'select * from public.boq_template_items where template_id = $1 order by sort_order', [id]),
    }));
  });

  app.post('/boq-templates', async (req, reply) => {
    const { items = [], ...body } = boqBody.parse(req.body);
    const row = await tx(db, req, async (t) => {
      const tpl = await insertRow<any>(t, 'boq_templates', body);
      let order = 0;
      for (const it of items) await insertRow(t, 'boq_template_items', { ...it, sort_order: it.sort_order ?? (order += 10), template_id: tpl.id });
      return tpl;
    });
    return reply.status(201).send(row);
  });

  // Replaces the header and, when given, the full item list.
  app.put('/boq-templates/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const { items, ...body } = boqBody.parse(req.body);
    return tx(db, req, async (t) => {
      const tpl = await updateOrFail(t, 'boq_templates', id, body, 'BOQ template');
      if (items) {
        await t.query('delete from public.boq_template_items where template_id = $1', [id]);
        let order = 0;
        for (const it of items) await insertRow(t, 'boq_template_items', { ...it, sort_order: it.sort_order ?? (order += 10), template_id: id });
      }
      return tpl;
    });
  });

  app.get('/quotation-templates', async (req) => tx(db, req, (t) => many(t, 'select * from public.quotation_templates order by name')));

  app.post('/quotation-templates', async (req, reply) => {
    const body = qtBody.parse(req.body);
    return reply.status(201).send(await tx(db, req, (t) => insertRow(t, 'quotation_templates', body)));
  });

  app.patch('/quotation-templates/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = qtBody.partial().parse(req.body);
    return tx(db, req, (t) => updateOrFail(t, 'quotation_templates', id, body, 'Quotation template'));
  });
}
