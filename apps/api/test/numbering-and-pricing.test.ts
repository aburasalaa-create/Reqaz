import { describe, expect, it } from 'vitest';
import pg from 'pg';
import { priceQuotation, type PricingParams } from '@rms/shared';
import { asUser, dbClient, DATABASE_URL, USERS } from './helpers.js';

describe('Sequential document numbers', () => {
  it('are unique and gap-free under concurrent creation, and rollbacks do not burn numbers', async () => {
    const pool = new pg.Pool({ connectionString: DATABASE_URL, max: 20 });
    const finance = (await pool.query('select id from public.app_users where email = $1', [USERS.finance])).rows[0].id;
    const create = async (i: number, rollback = false) => {
      const cl = await pool.connect();
      try {
        await cl.query('begin');
        await cl.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: finance, role: 'authenticated' })]);
        await cl.query('set local role authenticated');
        const r = await cl.query(`insert into public.suppliers (name_en) values ($1) returning code`, [`Concurrent ${i}`]);
        await cl.query(rollback ? 'rollback' : 'commit');
        return r.rows[0].code as string;
      } finally { cl.release(); }
    };
    await create(-1, true); // burns nothing
    const codes = await Promise.all(Array.from({ length: 25 }, (_, i) => create(i)));
    const nums = codes.map((x) => Number(x.split('-')[1])).sort((a, b) => a - b);
    expect(new Set(codes).size).toBe(25);
    expect(nums[nums.length - 1] - nums[0]).toBe(24);
    const all = (await pool.query(`select code from public.suppliers order by code`)).rows.map((r) => Number(r.code.split('-')[1]));
    expect(all).toEqual(Array.from({ length: all.length }, (_, i) => i + 1));
    await pool.end();
  });

  it('document numbers cannot be edited', async () => {
    const c = await dbClient();
    await asUser(c, USERS.admin, () => expect(c.query(`update public.customers set code = 'CUS-99999'`)).rejects.toThrow(/cannot be changed/));
    await c.end();
  });
});

describe('Database pricing engine matches the TypeScript engine', () => {
  it('agrees on 60 randomised quotations to the halala', async () => {
    const c = await dbClient();
    let seed = 20261027;
    const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
    const dec = (max: number, dp: number) => (rnd() * max).toFixed(dp);
    try {
      await asUser(c, USERS.estimator, async () => {
        for (let n = 0; n < 60; n++) {
          const q = await c.query(`select public.create_quotation($1, $2) as id`, ['20000000-0000-4000-8000-000000000001', `Parity ${n}`]);
          const rev = (await c.query('select id from public.quotation_revisions where quotation_id = $1', [q.rows[0].id])).rows[0].id;
          const method = rnd() < 0.5 ? 'markup' : 'margin';
          const dtype = (['none', 'percent', 'amount'] as const)[Math.floor(rnd() * 3)];
          const params: PricingParams = {
            overhead_pct: dec(25, 3), contingency_pct: dec(10, 3), pricing_method: method, markup_pct: dec(40, 3),
            target_margin_pct: dec(45, 3), discount_type: dtype, discount_value: dtype === 'percent' ? dec(10, 2) : dec(20000, 2),
            vat_rate: rnd() < 0.8 ? '15' : '0',
          };
          await c.query(`update public.quotation_revisions set overhead_pct=$2, contingency_pct=$3, pricing_method=$4, markup_pct=$5,
            target_margin_pct=$6, discount_type=$7, discount_value=$8, vat_rate=$9 where id=$1`,
            [rev, params.overhead_pct, params.contingency_pct, params.pricing_method, params.markup_pct, params.target_margin_pct,
             params.discount_type, params.discount_value, params.vat_rate]);
          const lines = Array.from({ length: 1 + Math.floor(rnd() * 15) }, () => ({
            quantity: dec(5000, 3), material_unit_cost: rnd() < 0.7 ? dec(900, 4) : '0', labour_unit_cost: rnd() < 0.6 ? dec(150, 4) : '0',
            equipment_unit_cost: rnd() < 0.4 ? dec(80, 4) : '0', subcontract_unit_cost: rnd() < 0.2 ? dec(50000, 4) : '0', other_unit_cost: rnd() < 0.2 ? dec(500, 4) : '0',
            manual_rate: rnd() < 0.3 ? dec(20000, 2) : null,
          }));
          for (const [i, l] of lines.entries()) {
            await c.query(`insert into public.quotation_lines (revision_id, sort_order, description_en, quantity, material_unit_cost, labour_unit_cost,
              equipment_unit_cost, subcontract_unit_cost, other_unit_cost, manual_rate) values ($1, $2, 'x', $3, $4, $5, $6, $7, $8, $9)`,
              [rev, i, l.quantity, l.material_unit_cost, l.labour_unit_cost, l.equipment_unit_cost, l.subcontract_unit_cost, l.other_unit_cost, l.manual_rate]);
          }
          const db = (await c.query('select * from public.quotation_revisions where id = $1', [rev])).rows[0];
          const dbLines = (await c.query('select sell_rate, sell_total from public.quotation_lines where revision_id = $1 order by sort_order', [rev])).rows;
          const ts = priceQuotation(lines, params);
          for (const k of ['direct_cost', 'overhead_amount', 'contingency_amount', 'total_cost', 'target_price', 'price_factor', 'subtotal',
            'discount_amount', 'net_amount', 'vat_amount', 'total_amount', 'gross_profit', 'gross_margin_pct'] as const) {
            expect(db[k], `case ${n} ${k}`).toBe(ts[k]);
          }
          dbLines.forEach((l, i) => expect([l.sell_rate, l.sell_total], `case ${n} line ${i}`).toEqual([ts.lines[i].sell_rate, ts.lines[i].sell_total]));
        }
      });
    } finally { await c.end(); }
  });
});
