// Quotation pricing engine — TypeScript mirror of public.recalculate_revision() in
// supabase/migrations/20261027000003_quotations.sql. The database is authoritative;
// this copy powers instant previews in the editor. Tests assert both agree exactly.
import Decimal from 'decimal.js';

const D = Decimal.clone({ precision: 60, rounding: Decimal.ROUND_HALF_UP });
type Num = Decimal.Value;

export type PricingMethod = 'markup' | 'margin';
export type DiscountType = 'none' | 'percent' | 'amount';

export interface PricingLineInput {
  quantity: Num;
  material_unit_cost?: Num;
  labour_unit_cost?: Num;
  equipment_unit_cost?: Num;
  subcontract_unit_cost?: Num;
  other_unit_cost?: Num;
}

export interface PricingParams {
  overhead_pct: Num;
  contingency_pct: Num;
  pricing_method: PricingMethod;
  markup_pct: Num;
  target_margin_pct: Num;
  discount_type: DiscountType;
  discount_value: Num;
  vat_rate: Num;
}

export interface PricedLine {
  unit_cost: string;
  cost_total: string;
  sell_rate: string;
  sell_total: string;
}

export interface PricingResult {
  material_cost: string;
  labour_cost: string;
  equipment_cost: string;
  subcontract_cost: string;
  other_cost: string;
  direct_cost: string;
  overhead_amount: string;
  contingency_amount: string;
  total_cost: string;
  target_price: string;
  price_factor: string;
  subtotal: string;
  discount_amount: string;
  net_amount: string;
  vat_amount: string;
  total_amount: string;
  gross_profit: string;
  gross_margin_pct: string | null;
  lines: PricedLine[];
}

const r2 = (v: Decimal) => v.toDecimalPlaces(2, Decimal.ROUND_HALF_UP);
const d = (v: Num | undefined | null) => new D(v ?? 0);
const fixed2 = (v: Decimal) => v.toFixed(2);

export function priceQuotation(lines: PricingLineInput[], p: PricingParams): PricingResult {
  if (d(p.target_margin_pct).gte(100)) throw new RangeError('Target margin must be below 100%');

  const cat = { material: new D(0), labour: new D(0), equipment: new D(0), subcontract: new D(0), other: new D(0) };
  const prepared = lines.map((l) => {
    const q = d(l.quantity);
    const m = r2(q.mul(d(l.material_unit_cost)));
    const lb = r2(q.mul(d(l.labour_unit_cost)));
    const e = r2(q.mul(d(l.equipment_unit_cost)));
    const s = r2(q.mul(d(l.subcontract_unit_cost)));
    const o = r2(q.mul(d(l.other_unit_cost)));
    cat.material = cat.material.add(m);
    cat.labour = cat.labour.add(lb);
    cat.equipment = cat.equipment.add(e);
    cat.subcontract = cat.subcontract.add(s);
    cat.other = cat.other.add(o);
    const unitCost = d(l.material_unit_cost).add(d(l.labour_unit_cost)).add(d(l.equipment_unit_cost))
      .add(d(l.subcontract_unit_cost)).add(d(l.other_unit_cost));
    return { q, unitCost, costTotal: m.add(lb).add(e).add(s).add(o) };
  });

  const direct = cat.material.add(cat.labour).add(cat.equipment).add(cat.subcontract).add(cat.other);
  const overhead = r2(direct.mul(d(p.overhead_pct)).div(100));
  const contingency = r2(direct.add(overhead).mul(d(p.contingency_pct)).div(100));
  const totalCost = direct.add(overhead).add(contingency);
  const target = p.pricing_method === 'markup'
    ? r2(totalCost.mul(new D(1).add(d(p.markup_pct).div(100))))
    : r2(totalCost.div(new D(1).sub(d(p.target_margin_pct).div(100))));
  const factor = direct.gt(0)
    ? target.div(direct).toDecimalPlaces(20, Decimal.ROUND_HALF_UP).toDecimalPlaces(10, Decimal.ROUND_HALF_UP)
    : new D(0);

  let subtotal = new D(0);
  const priced = prepared.map(({ q, unitCost, costTotal }) => {
    const rate = r2(unitCost.mul(factor));
    const total = r2(q.mul(rate));
    subtotal = subtotal.add(total);
    return { unit_cost: unitCost.toFixed(4), cost_total: fixed2(costTotal), sell_rate: fixed2(rate), sell_total: fixed2(total) };
  });

  let discount = new D(0);
  if (p.discount_type === 'percent') discount = r2(subtotal.mul(Decimal.min(d(p.discount_value), 100)).div(100));
  else if (p.discount_type === 'amount') discount = Decimal.min(r2(d(p.discount_value)), subtotal);
  const net = subtotal.sub(discount);
  const vat = r2(net.mul(d(p.vat_rate)).div(100));
  const gp = net.sub(totalCost);

  return {
    material_cost: fixed2(cat.material),
    labour_cost: fixed2(cat.labour),
    equipment_cost: fixed2(cat.equipment),
    subcontract_cost: fixed2(cat.subcontract),
    other_cost: fixed2(cat.other),
    direct_cost: fixed2(direct),
    overhead_amount: fixed2(overhead),
    contingency_amount: fixed2(contingency),
    total_cost: fixed2(totalCost),
    target_price: fixed2(target),
    price_factor: factor.toFixed(10),
    subtotal: fixed2(subtotal),
    discount_amount: fixed2(discount),
    net_amount: fixed2(net),
    vat_amount: fixed2(vat),
    total_amount: fixed2(net.add(vat)),
    gross_profit: fixed2(gp),
    gross_margin_pct: net.gt(0) ? fixed2(r2(gp.div(net).mul(100))) : null,
    lines: priced,
  };
}
