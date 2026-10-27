import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { insertRow, many, type Db, inSequence } from '../db.js';
import { notFound } from '../errors.js';
import { getOr404, idParam, listQuery, optEmail, optText, reqText, tx, updateOrFail, decimal } from './util.js';

const vat = z.union([z.literal(''), z.string().trim().regex(/^3\d{13}3$/, 'Saudi VAT numbers have 15 digits and start and end with 3')])
  .nullish().transform((v) => (v === undefined ? undefined : v || null));

const customerBody = z.object({
  party_type: z.enum(['company', 'government', 'individual']).optional(),
  name_en: reqText(300),
  name_ar: optText,
  cr_number: optText,
  vat_number: vat,
  email: optEmail,
  phone: optText,
  website: optText,
  building_number: optText,
  street: optText,
  district: optText,
  city: optText,
  postal_code: optText,
  country: z.string().length(2).toUpperCase().optional(),
  payment_terms_days: z.coerce.number().int().min(0).max(365).optional(),
  currency: z.string().length(3).toUpperCase().optional(),
  credit_limit: decimal.nullish(),
  notes: optText,
  is_active: z.boolean().optional(),
});

const contactBody = z.object({
  full_name: reqText(200),
  position: optText,
  email: optEmail,
  phone: optText,
  is_primary: z.boolean().optional(),
  notes: optText,
});

const supplierBody = z.object({
  name_en: reqText(300),
  name_ar: optText,
  category: optText,
  cr_number: optText,
  vat_number: vat,
  email: optEmail,
  phone: optText,
  city: optText,
  country: z.string().length(2).toUpperCase().optional(),
  payment_terms_days: z.coerce.number().int().min(0).max(365).optional(),
  currency: z.string().length(3).toUpperCase().optional(),
  contact_name: optText,
  notes: optText,
  is_active: z.boolean().optional(),
});

export default async function partyRoutes(app: FastifyInstance, { db }: { db: Db }) {
  // Customers ---------------------------------------------------------------
  app.get('/customers', async (req) => {
    const q = listQuery.extend({ active: z.enum(['true', 'false', 'all']).default('true') }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select c.*, (select count(*) from public.opportunities o where o.customer_id = c.id)::int as opportunity_count
      from public.customers c
      where ($1::text is null or c.name_en ilike '%' || $1 || '%' or c.name_ar ilike '%' || $1 || '%'
             or c.code ilike '%' || $1 || '%' or c.vat_number = $1 or c.email ilike '%' || $1 || '%')
        and ($2 = 'all' or c.is_active = ($2 = 'true'))
      order by c.name_en limit $3 offset $4`, [q.q || null, q.active, q.limit, q.offset]));
  });

  app.post('/customers', async (req, reply) => {
    const body = customerBody.parse(req.body);
    const row = await tx(db, req, (t) => insertRow(t, 'customers', body));
    return reply.status(201).send(row);
  });

  app.get('/customers/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const customer = await getOr404(t, 'select * from public.customers where id = $1', [id], 'Customer');
      const [contacts, opportunities, quotations] = await inSequence([
        () => many(t, 'select * from public.contacts where customer_id = $1 order by is_primary desc, full_name', [id]),
        () => many(t, 'select id, number, title, stage, expected_value, currency, created_at from public.opportunities where customer_id = $1 order by created_at desc', [id]),
        () => many(t, `select q.id, q.number, q.title, q.status, q.currency, r.revision_no, r.status as revision_status, r.total_amount
                 from public.quotations q
                 left join lateral (select * from public.quotation_revisions r where r.quotation_id = q.id order by revision_no desc limit 1) r on true
                 where q.customer_id = $1 order by q.created_at desc`, [id]),
      ]);
      return { ...customer, contacts, opportunities, quotations };
    });
  });

  app.patch('/customers/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = customerBody.partial().parse(req.body);
    return tx(db, req, (t) => updateOrFail(t, 'customers', id, body, 'Customer'));
  });

  app.post('/customers/:id/contacts', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const body = contactBody.parse(req.body);
    const row = await tx(db, req, async (t) => {
      if (body.is_primary) await t.query('update public.contacts set is_primary = false where customer_id = $1 and is_primary', [id]);
      return insertRow(t, 'contacts', { ...body, customer_id: id });
    });
    return reply.status(201).send(row);
  });

  app.patch('/contacts/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = contactBody.partial().parse(req.body);
    return tx(db, req, async (t) => {
      if (body.is_primary) {
        await t.query(`update public.contacts set is_primary = false
                       where customer_id = (select customer_id from public.contacts where id = $1) and is_primary and id <> $1`, [id]);
      }
      return updateOrFail(t, 'contacts', id, body, 'Contact');
    });
  });

  app.delete('/contacts/:id', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    await tx(db, req, async (t) => {
      const r = await t.query('delete from public.contacts where id = $1', [id]);
      if (!r.rowCount) throw notFound('Contact');
    });
    return reply.status(204).send();
  });

  // Suppliers ---------------------------------------------------------------
  app.get('/suppliers', async (req) => {
    const q = listQuery.parse(req.query);
    return tx(db, req, (t) => many(t, `
      select * from public.suppliers
      where ($1::text is null or name_en ilike '%' || $1 || '%' or name_ar ilike '%' || $1 || '%' or code ilike '%' || $1 || '%')
      order by name_en limit $2 offset $3`, [q.q || null, q.limit, q.offset]));
  });

  app.post('/suppliers', async (req, reply) => {
    const body = supplierBody.parse(req.body);
    return reply.status(201).send(await tx(db, req, (t) => insertRow(t, 'suppliers', body)));
  });

  app.get('/suppliers/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, (t) => getOr404(t, 'select * from public.suppliers where id = $1', [id], 'Supplier'));
  });

  app.patch('/suppliers/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    const body = supplierBody.partial().parse(req.body);
    return tx(db, req, (t) => updateOrFail(t, 'suppliers', id, body, 'Supplier'));
  });
}
