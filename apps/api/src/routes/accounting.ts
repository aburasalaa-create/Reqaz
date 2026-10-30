import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { insertRow, many, one, type Db } from '../db.js';
import { HttpError } from '../errors.js';
import { decimal, getOr404, idParam, listQuery, optText, requirePermission, tx } from './util.js';

// General ledger, trial balance, manual journals and bank reconciliation. Entries are only ever posted by the database.

const accountBody = z.object({
  name_en: z.string().trim().min(1).max(200).optional(), name_ar: optText, bank_name: optText, iban: optText, is_active: z.boolean().optional(),
}).strict();

export default async function accountingRoutes(app: FastifyInstance, { db }: { db: Db }) {
  app.get('/accounts', async (req) => tx(db, req, async (t) => {
    const canRead = (await one<any>(t, `select public.has_permission('accounting.read') as ok`))?.ok;
    return many(t, canRead ? 'select * from public.account_balances order by code'
      : 'select code, name_en, name_ar, type, is_bank, system_key from public.accounts where is_active order by code');
  }));

  app.post('/accounts', async (req, reply) => {
    const body = accountBody.extend({
      code: z.string().regex(/^[0-9]{3,8}$/), name_en: z.string().trim().min(1).max(200),
      type: z.enum(['asset', 'liability', 'equity', 'income', 'expense']), is_bank: z.boolean().optional(),
    }).parse(req.body);
    const r = await tx(db, req, (t) => insertRow(t, 'accounts', body));
    return reply.status(201).send(r);
  });

  app.patch('/accounts/:code', async (req) => {
    const { code } = z.object({ code: z.string().regex(/^[0-9]{3,8}$/) }).parse(req.params);
    const body = accountBody.parse(req.body);
    return tx(db, req, async (t) => {
      const cols = Object.keys(body).filter((k) => (body as any)[k] !== undefined);
      if (!cols.length) return getOr404(t, 'select * from public.accounts where code = $1', [code], 'Account');
      const r = await t.query(`update public.accounts set ${cols.map((c, i) => `"${c}" = $${i + 2}`).join(', ')} where code = $1 returning *`,
        [code, ...cols.map((c) => (body as any)[c])]);
      if (!r.rowCount) throw new HttpError(403, 'You do not have permission for this action', 'forbidden');
      return r.rows[0];
    });
  });

  app.get('/journals', async (req) => {
    const q = listQuery.extend({
      account: z.string().max(8).optional(), source_type: z.string().max(40).optional(), project_id: z.uuid().optional(),
      from: z.iso.date().optional(), to: z.iso.date().optional(),
    }).parse(req.query);
    return tx(db, req, (t) => many(t, `
      select e.id, e.number, e.entry_date, e.source_type, e.source_id, e.event, e.memo, e.total, e.reverses_id, e.created_at,
             (select number from public.journal_entries r where r.id = e.reverses_id) as reverses_number,
             exists (select 1 from public.journal_entries r where r.reverses_id = e.id) as reversed,
             (select json_agg(json_build_object('account_code', l.account_code, 'account_name', a.name_en, 'debit', l.debit, 'credit', l.credit,
                       'project_id', l.project_id, 'cost_category', l.cost_category, 'description', l.description) order by l.line_no)
                from public.journal_lines l join public.accounts a on a.code = l.account_code where l.entry_id = e.id) as lines
      from public.journal_entries e
      where ($1::text is null or exists (select 1 from public.journal_lines l where l.entry_id = e.id and l.account_code = $1))
        and ($2::text is null or e.source_type = $2)
        and ($3::uuid is null or exists (select 1 from public.journal_lines l where l.entry_id = e.id and l.project_id = $3))
        and ($4::date is null or e.entry_date >= $4) and ($5::date is null or e.entry_date <= $5)
        and ($6::text is null or e.number ilike '%' || $6 || '%' or e.memo ilike '%' || $6 || '%')
      order by e.entry_date desc, e.number desc limit $7 offset $8`,
      [q.account ?? null, q.source_type ?? null, q.project_id ?? null, q.from ?? null, q.to ?? null, q.q || null, q.limit, q.offset]));
  });

  // Trial balance as at a date; total debits always equal total credits.
  app.get('/trial-balance', async (req) => {
    const { to } = z.object({ to: z.iso.date().optional() }).parse(req.query);
    return tx(db, req, async (t) => {
      await requirePermission(t, 'accounting.read');
      const rows = await many<any>(t, `
        select a.code, a.name_en, a.name_ar, a.type, coalesce(sum(l.debit), 0) as debit, coalesce(sum(l.credit), 0) as credit
        from public.accounts a left join public.journal_lines l on l.account_code = a.code
          and ($1::date is null or exists (select 1 from public.journal_entries e where e.id = l.entry_id and e.entry_date <= $1))
        group by a.code having coalesce(sum(l.debit), 0) <> 0 or coalesce(sum(l.credit), 0) <> 0 order by a.code`, [to ?? null]);
      const totals = await one<any>(t, `
        select coalesce(sum(l.debit), 0) as debit, coalesce(sum(l.credit), 0) as credit from public.journal_lines l
        where $1::date is null or exists (select 1 from public.journal_entries e where e.id = l.entry_id and e.entry_date <= $1)`, [to ?? null]);
      return { rows, totals, balanced: totals?.debit === totals?.credit };
    });
  });

  app.post('/journals', async (req, reply) => {
    const body = z.object({
      entry_date: z.iso.date(), memo: z.string().trim().min(1).max(500),
      lines: z.array(z.object({ account: z.string().regex(/^[0-9]{3,8}$/), debit: decimal.optional(), credit: decimal.optional(),
        project_id: z.uuid().nullish(), cost_category: z.string().max(30).nullish(), description: optText }).strict()).min(2).max(100),
    }).strict().parse(req.body);
    const r = await tx(db, req, async (t) => {
      const e = await one<any>(t, 'select public.post_manual_journal($1, $2, $3::jsonb) as id', [body.entry_date, body.memo, JSON.stringify(body.lines)]);
      return one(t, 'select * from public.journal_entries where id = $1', [e!.id]);
    });
    return reply.status(201).send(r);
  });

  app.post('/journals/:id/reverse', async (req) => {
    const { id } = idParam.parse(req.params);
    const { reason } = z.object({ reason: z.string().trim().min(1).max(500) }).parse(req.body ?? {});
    return tx(db, req, async (t) => { await t.query('select public.reverse_manual_journal($1, $2)', [id, reason]); return { ok: true }; });
  });

  // Bank reconciliation ----------------------------------------------------------------
  app.get('/bank-reconciliation/:code', async (req) => {
    const { code } = z.object({ code: z.string().regex(/^[0-9]{3,8}$/) }).parse(req.params);
    const { opening_balance } = z.object({ opening_balance: decimal.optional() }).parse(req.query);
    return tx(db, req, async (t) => {
      await requirePermission(t, 'accounting.read');
      const account = await getOr404<any>(t, 'select * from public.account_balances where code = $1 and is_bank', [code], 'Bank account');
      const statement = await many<any>(t, `
        select s.*, e.number as journal_number, e.memo as journal_memo from public.bank_statement_lines s
        left join public.journal_lines l on l.id = s.journal_line_id left join public.journal_entries e on e.id = l.entry_id
        where s.account_code = $1 order by s.txn_date, s.created_at`, [code]);
      const unmatchedLedger = await many<any>(t, `
        select l.id, e.number, e.entry_date, e.memo, l.description, l.debit - l.credit as amount
        from public.journal_lines l join public.journal_entries e on e.id = l.entry_id
        where l.account_code = $1 and not exists (select 1 from public.bank_statement_lines s where s.journal_line_id = l.id)
        order by e.entry_date, e.number`, [code]);
      // Suggestions: same amount, within 10 days.
      for (const s of statement.filter((x) => !x.journal_line_id)) {
        s.suggestions = unmatchedLedger.filter((l) => Number(l.amount) === Number(s.amount)
          && Math.abs(new Date(l.entry_date).getTime() - new Date(s.txn_date).getTime()) <= 10 * 86400000).slice(0, 3).map((l) => l.id);
      }
      const statementTotal = statement.reduce((a, s) => a + Number(s.amount), 0) + Number(opening_balance ?? 0);
      const unmatchedStatement = statement.filter((s) => !s.journal_line_id).reduce((a, s) => a + Number(s.amount), 0);
      const unmatchedBook = unmatchedLedger.reduce((a, l) => a + Number(l.amount), 0);
      const book = Number(account.balance);
      return {
        account, statement, unmatched_ledger: unmatchedLedger,
        summary: {
          statement_balance: statementTotal.toFixed(2), ledger_balance: book.toFixed(2),
          unmatched_statement: unmatchedStatement.toFixed(2), unmatched_ledger: unmatchedBook.toFixed(2),
          difference: (statementTotal - unmatchedStatement - (book - unmatchedBook)).toFixed(2),
          reconciled: Math.abs(statementTotal - unmatchedStatement - (book - unmatchedBook)) < 0.005 && statement.every((s) => s.journal_line_id),
        },
      };
    });
  });

  app.post('/bank-reconciliation/:code/lines', async (req, reply) => {
    const { code } = z.object({ code: z.string().regex(/^[0-9]{3,8}$/) }).parse(req.params);
    const lines = z.array(z.object({ txn_date: z.iso.date(), description: z.string().trim().min(1).max(500), reference: optText, amount: decimal }).strict())
      .min(1).max(1000).parse(req.body);
    const r = await tx(db, req, async (t) => {
      const out = [];
      for (const l of lines) out.push(await insertRow(t, 'bank_statement_lines', { ...l, account_code: code }));
      return out;
    });
    return reply.status(201).send(r);
  });

  app.delete('/bank-statement-lines/:id', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => {
      const r = await t.query('delete from public.bank_statement_lines where id = $1', [id]);
      if (!r.rowCount) throw new HttpError(404, 'Statement line not found', 'not_found');
      return { ok: true };
    });
  });

  app.post('/bank-statement-lines/:id/match', async (req) => {
    const { id } = idParam.parse(req.params);
    const { journal_line_id } = z.object({ journal_line_id: z.uuid() }).parse(req.body);
    return tx(db, req, async (t) => { await t.query('select public.match_bank_line($1, $2)', [id, journal_line_id]); return { ok: true }; });
  });

  app.post('/bank-statement-lines/:id/unmatch', async (req) => {
    const { id } = idParam.parse(req.params);
    return tx(db, req, async (t) => { await t.query('select public.unmatch_bank_line($1)', [id]); return { ok: true }; });
  });

  app.post('/bank-statement-lines/:id/post', async (req) => {
    const { id } = idParam.parse(req.params);
    const { account, memo } = z.object({ account: z.string().regex(/^[0-9]{3,8}$/), memo: optText }).parse(req.body);
    return tx(db, req, async (t) => { await t.query('select public.post_bank_line($1, $2, $3)', [id, account, memo ?? null]); return { ok: true }; });
  });

  // Approval levels (Settings) -------------------------------------------------------------
  app.get('/approval-levels', async (req) => tx(db, req, (t) => many(t, `
    select l.*, r.name_en as role_name, r.code as role_code from public.approval_levels l left join public.roles r on r.id = l.role_id
    order by l.doc_type, l.level`)));

  app.put('/approval-levels/:doc_type', async (req) => {
    const { doc_type } = z.object({ doc_type: z.enum(['purchase_request', 'purchase_order', 'customer_po', 'budget_change', 'variation', 'supplier_invoice']) }).parse(req.params);
    const levels = z.array(z.object({ min_amount: decimal, role_id: z.uuid().nullish() }).strict()).max(9).parse(req.body);
    return tx(db, req, async (t) => {
      await requirePermission(t, 'settings.manage');
      await t.query('delete from public.approval_levels where doc_type = $1', [doc_type]);
      let level = 0;
      for (const l of [...levels].sort((a, b) => Number(a.min_amount) - Number(b.min_amount))) {
        level += 1;
        await insertRow(t, 'approval_levels', { doc_type, level, min_amount: l.min_amount, role_id: l.role_id ?? null });
      }
      return many(t, 'select * from public.approval_levels where doc_type = $1 order by level', [doc_type]);
    });
  });

}
