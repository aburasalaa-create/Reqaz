import { describe, expect, it } from 'vitest';
import { priceQuotation, type PricingParams } from './pricing';

const base: PricingParams = {
  overhead_pct: 10, contingency_pct: 5, pricing_method: 'markup', markup_pct: 15, target_margin_pct: 15,
  discount_type: 'none', discount_value: 0, vat_rate: 15,
};

describe('priceQuotation', () => {
  it('prices a worked construction example (hand-calculated)', () => {
    const r = priceQuotation([
      { quantity: 100, material_unit_cost: 250, labour_unit_cost: 40, equipment_unit_cost: 15 },
      { quantity: 1, subcontract_unit_cost: 12000 },
    ], base);
    expect(r.material_cost).toBe('25000.00');
    expect(r.labour_cost).toBe('4000.00');
    expect(r.equipment_cost).toBe('1500.00');
    expect(r.subcontract_cost).toBe('12000.00');
    expect(r.direct_cost).toBe('42500.00');
    expect(r.overhead_amount).toBe('4250.00');
    expect(r.contingency_amount).toBe('2337.50');
    expect(r.total_cost).toBe('49087.50');
    expect(r.target_price).toBe('56450.63');
    expect(r.price_factor).toBe('1.3282501176');
    expect(r.lines[0]).toMatchObject({ unit_cost: '305.0000', cost_total: '30500.00', sell_rate: '405.12', sell_total: '40512.00' });
    expect(r.lines[1]).toMatchObject({ sell_rate: '15939.00', sell_total: '15939.00' });
    expect(r.subtotal).toBe('56451.00');
    expect(r.discount_amount).toBe('0.00');
    expect(r.net_amount).toBe('56451.00');
    expect(r.vat_amount).toBe('8467.65');
    expect(r.total_amount).toBe('64918.65');
    expect(r.gross_profit).toBe('7363.50');
    expect(r.gross_margin_pct).toBe('13.04');
  });

  it('prices to a target margin', () => {
    // cost 1000 → price = 1000 / (1 − 0.20) = 1250
    const r = priceQuotation([{ quantity: 1, material_unit_cost: 1000 }],
      { ...base, overhead_pct: 0, contingency_pct: 0, pricing_method: 'margin', target_margin_pct: 20 });
    expect(r.target_price).toBe('1250.00');
    expect(r.subtotal).toBe('1250.00');
    expect(r.gross_margin_pct).toBe('20.00');
  });

  it('applies percentage and fixed discounts before VAT', () => {
    const lines = [{ quantity: 1, material_unit_cost: 1000 }];
    const p = { ...base, overhead_pct: 0, contingency_pct: 0, markup_pct: 0 };
    const pct = priceQuotation(lines, { ...p, discount_type: 'percent', discount_value: 2.5 });
    expect(pct.discount_amount).toBe('25.00');
    expect(pct.net_amount).toBe('975.00');
    expect(pct.vat_amount).toBe('146.25');
    expect(pct.total_amount).toBe('1121.25');
    const amt = priceQuotation(lines, { ...p, discount_type: 'amount', discount_value: 100 });
    expect(amt.net_amount).toBe('900.00');
    expect(amt.vat_amount).toBe('135.00');
  });

  it('never discounts below zero', () => {
    const r = priceQuotation([{ quantity: 1, material_unit_cost: 50 }],
      { ...base, overhead_pct: 0, contingency_pct: 0, markup_pct: 0, discount_type: 'amount', discount_value: 999 });
    expect(r.discount_amount).toBe('50.00');
    expect(r.net_amount).toBe('0.00');
    expect(r.vat_amount).toBe('0.00');
    expect(r.gross_margin_pct).toBeNull();
  });

  it('rounds half away from zero at each documented step', () => {
    const r = priceQuotation([{ quantity: 1, material_unit_cost: '0.005' }],
      { ...base, overhead_pct: 0, contingency_pct: 0, markup_pct: 0 });
    expect(r.material_cost).toBe('0.01');
    // VAT on 0.10 at 15% = 0.015 → 0.02
    const v = priceQuotation([{ quantity: 1, material_unit_cost: '0.10' }],
      { ...base, overhead_pct: 0, contingency_pct: 0, markup_pct: 0 });
    expect(v.vat_amount).toBe('0.02');
  });

  it('handles an empty quotation', () => {
    const r = priceQuotation([], base);
    expect(r.direct_cost).toBe('0.00');
    expect(r.price_factor).toBe('0.0000000000');
    expect(r.total_amount).toBe('0.00');
  });

  it('keeps document totals internally consistent', () => {
    const lines = Array.from({ length: 37 }, (_, i) => ({
      quantity: (i * 7.125) % 91 + 0.5, material_unit_cost: (i * 13.37) % 400, labour_unit_cost: (i * 3.3) % 50,
    }));
    const r = priceQuotation(lines, { ...base, discount_type: 'percent', discount_value: 3 });
    const sum = r.lines.reduce((a, l) => a + Math.round(Number(l.sell_total) * 100), 0);
    expect(sum).toBe(Math.round(Number(r.subtotal) * 100));
    expect(Math.round(Number(r.net_amount) * 100) + Math.round(Number(r.vat_amount) * 100))
      .toBe(Math.round(Number(r.total_amount) * 100));
  });

  it('rejects a margin of 100% or more', () => {
    expect(() => priceQuotation([], { ...base, pricing_method: 'margin', target_margin_pct: 100 })).toThrow();
  });
});

describe('typed rates', () => {
  const p = { overhead_pct: 10, contingency_pct: 5, pricing_method: 'markup' as const, markup_pct: 20, target_margin_pct: 0, discount_type: 'none' as const, discount_value: 0, vat_rate: 15 };
  it('prices a line as quantity × typed rate and shows no margin without costs', () => {
    const r = priceQuotation([{ quantity: '12.5', manual_rate: '310.40' }, { quantity: 2, manual_rate: 1000 }], p);
    expect(r.lines.map((l) => l.sell_total)).toEqual(['3880.00', '2000.00']);
    expect(r.subtotal).toBe('5880.00');
    expect(r.vat_amount).toBe('882.00');
    expect(r.total_amount).toBe('6762.00');
    expect(r.gross_margin_pct).toBeNull();
  });
  it('mixes typed rates with cost-based lines', () => {
    const r = priceQuotation([{ quantity: 1, material_unit_cost: 100 }, { quantity: 1, material_unit_cost: 50, manual_rate: 80 }], p);
    expect(r.lines[1].sell_rate).toBe('80.00');
    expect(r.gross_margin_pct).not.toBeNull();
  });
});
