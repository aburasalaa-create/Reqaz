import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { insertRow, many, one, type Db } from '../db.js';
import { HttpError, notFound } from '../errors.js';
import { newStorageKey, sha256, type Storage } from '../storage.js';
import { idParam, tx } from './util.js';

const ENTITY_TYPES = ['customer', 'opportunity', 'tender', 'quotation', 'quotation_revision', 'contract', 'project', 'expense'] as const;
const ENTITY_TABLE: Record<(typeof ENTITY_TYPES)[number], string> = {
  customer: 'customers', opportunity: 'opportunities', tender: 'tenders', quotation: 'quotations',
  quotation_revision: 'quotation_revisions', contract: 'contracts', project: 'projects', expense: 'expenses',
};
// Office documents, PDFs, images, drawings and archives commonly exchanged in tenders.
const ALLOWED = /^(application\/(pdf|zip|x-zip-compressed|msword|vnd\.openxmlformats-officedocument\..+|vnd\.ms-excel|vnd\.ms-powerpoint|acad|x-autocad|dxf|octet-stream)|image\/(png|jpeg|webp|gif|tiff)|text\/(plain|csv))$/;

export default async function attachmentRoutes(app: FastifyInstance, { db, storage }: { db: Db; storage: Storage }) {
  app.get('/attachments', async (req) => {
    const q = z.object({ entity_type: z.enum(ENTITY_TYPES), entity_id: z.uuid() }).parse(req.query);
    return tx(db, req, (t) => many(t, `select a.*, u.full_name as uploaded_by_name from public.attachments a
      left join public.app_users u on u.id = a.uploaded_by
      where a.entity_type = $1 and a.entity_id = $2 and a.deleted_at is null order by a.created_at desc`, [q.entity_type, q.entity_id]));
  });

  app.post('/attachments', async (req, reply) => {
    const part = await req.file();
    if (!part) throw new HttpError(400, 'No file uploaded', 'validation');
    const fields = z.object({ entity_type: z.enum(ENTITY_TYPES), entity_id: z.uuid(), category: z.string().max(100).optional() })
      .parse(Object.fromEntries(Object.entries(part.fields).map(([k, v]: [string, any]) => [k, v?.value])));
    if (!ALLOWED.test(part.mimetype)) throw new HttpError(415, `File type ${part.mimetype} is not allowed`, 'unsupported_type');
    const body = await part.toBuffer();
    if (part.file.truncated) throw new HttpError(413, 'File is too large', 'too_large');
    const fileName = part.filename.replace(/[\\/\0]/g, '_').slice(0, 255);

    const row = await tx(db, req, async (t) => {
      // The parent must exist and be visible to this user.
      const parent = await one(t, `select 1 from public."${ENTITY_TABLE[fields.entity_type]}" where id = $1`, [fields.entity_id]);
      if (!parent) throw notFound('Parent record');
      const key = newStorageKey(fields.entity_type, fields.entity_id, fileName);
      const att = await insertRow(t, 'attachments', {
        entity_type: fields.entity_type, entity_id: fields.entity_id, file_name: fileName, mime_type: part.mimetype,
        size_bytes: body.length, sha256: sha256(body), storage_path: key, category: fields.category ?? null, uploaded_by: req.user.id,
      });
      // Upload last: if the register insert fails (e.g. no permission) nothing is stored.
      await storage.put(key, body, part.mimetype);
      return att;
    });
    return reply.status(201).send(row);
  });

  app.get('/attachments/:id/download', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    const att = await tx(db, req, (t) => one(t, 'select * from public.attachments where id = $1 and deleted_at is null', [id]));
    if (!att) throw notFound('Attachment');
    const body = await storage.get(att.storage_path);
    return reply.header('Content-Type', att.mime_type)
      .header('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(att.file_name)}`)
      .header('Cache-Control', 'no-store')
      .header('X-Content-Type-Options', 'nosniff')
      .send(body);
  });

  app.delete('/attachments/:id', async (req, reply) => {
    const { id } = idParam.parse(req.params);
    await tx(db, req, async (t) => {
      const r = await t.query('update public.attachments set deleted_at = now(), deleted_by = $2 where id = $1 and deleted_at is null', [id, req.user.id]);
      if (!r.rowCount) {
        const visible = await one(t, 'select 1 from public.attachments where id = $1', [id]);
        throw visible ? new HttpError(403, 'You do not have permission for this action', 'forbidden') : notFound('Attachment');
      }
    });
    return reply.status(204).send();
  });
}
