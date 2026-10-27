// End-to-end CRM → tender → quotation → approval → submission → award, through the HTTP API,
// with each step performed by the role that does it in practice.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { priceQuotation } from '@rms/shared';
import { dbClient, startServer, userId } from './helpers.js';

let s: Awaited<ReturnType<typeof startServer>>;
const ids: Record<string, string> = {};

beforeAll(async () => { s = await startServer(); });
afterAll(async () => { await s.close(); });

describe('CRM to quotation to contract', () => {
  it('sales records a new customer and lead', async () => {
    const c = await s.call('sales', 'POST', '/customers', {
      name_en: 'Red Sea Hospitality Co.', name_ar: 'شركة البحر الأحمر للضيافة', vat_number: '312345678900003',
      city: 'Jeddah', email: 'projects@redsea.test',
    });
    expect(c.status).toBe(201);
    expect(c.data.code).toMatch(/^CUS-\d{5}$/);
    ids.customer = c.data.id;

    const bad = await s.call('sales', 'POST', '/customers', { name_en: 'Bad VAT', vat_number: '123' });
    expect(bad.status).toBe(400);

    const contact = await s.call('sales', 'POST', `/customers/${ids.customer}/contacts`, { full_name: 'Eng. Lina Saleh', position: 'Development Manager', is_primary: true });
    expect(contact.status).toBe(201);
    ids.contact = contact.data.id;

    const o = await s.call('sales', 'POST', '/opportunities', {
      title: 'Hotel staff housing — civil works', source: 'referral', expected_value: '3500000', win_probability: 25,
      prospect_company: 'Red Sea Hospitality',
    });
    expect(o.status).toBe(201);
    expect(o.data.number).toMatch(/^OPP-\d{4}-\d{4}$/);
    expect(o.data.stage).toBe('new_lead');
    ids.opp = o.data.id;
  });

  it('enforces pipeline rules', async () => {
    // A customer must be linked before the tender stages.
    const early = await s.call('sales', 'PATCH', `/opportunities/${ids.opp}`, { stage: 'estimation' });
    expect(early.status).toBe(422);
    const won = await s.call('sales', 'PATCH', `/opportunities/${ids.opp}`, { stage: 'won' });
    expect(won.status).toBe(422);
    const q = await s.call('sales', 'PATCH', `/opportunities/${ids.opp}`, { stage: 'qualified', customer_id: ids.customer });
    expect(q.status).toBe(200);
    expect(q.data.stage).toBe('qualified');
    const lost = await s.call('sales', 'PATCH', `/opportunities/${ids.opp}`, { stage: 'lost' });
    expect(lost.status).toBe(422); // needs a reason
  });

  it('sales logs a follow-up and receives the tender', async () => {
    const f = await s.call('sales', 'POST', '/follow-ups', { opportunity_id: ids.opp, type: 'meeting', subject: 'Kick-off meeting', due_at: new Date(Date.now() + 86400000).toISOString() });
    expect(f.status).toBe(201);
    const done = await s.call('sales', 'PATCH', `/follow-ups/${f.data.id}`, { completed: true, outcome: 'Received RFQ pack' });
    expect(done.data.completed_at).toBeTruthy();

    const t = await s.call('sales', 'POST', '/tenders', {
      opportunity_id: ids.opp, client_reference: 'RSH-RFQ-88', title: 'Staff housing blocks A–C',
      submission_deadline: new Date(Date.now() + 10 * 86400000).toISOString(), bid_bond_required: true, bid_bond_amount: '70000',
    });
    expect(t.status).toBe(201);
    expect(t.data.number).toMatch(/^TND-\d{4}-\d{4}$/);
    expect(t.data.customer_id).toBe(ids.customer);
    ids.tender = t.data.id;
    const opp = await s.call('sales', 'GET', `/opportunities/${ids.opp}`);
    expect(opp.data.stage).toBe('tender_received');
    expect(opp.data.next_tender_deadline).toBeTruthy();
  });

  it('estimator builds a priced quotation from templates', async () => {
    const tpl = (await s.call('estimator', 'GET', '/quotation-templates')).data[0];
    const boq = (await s.call('estimator', 'GET', '/boq-templates')).data[0];
    const q = await s.call('estimator', 'POST', '/quotations', { opportunity_id: ids.opp, tender_id: ids.tender, title: 'Staff housing civil works', template_id: tpl.id });
    expect(q.status).toBe(201);
    expect(q.data.number).toMatch(/^QTN-\d{4}-\d{4}$/);
    ids.quotation = q.data.id;
    ids.rev0 = q.data.revision_id;

    const applied = await s.call('estimator', 'POST', `/revisions/${ids.rev0}/apply-boq-template`, { template_id: boq.id });
    expect(applied.data.inserted).toBe(7);

    const added = await s.call('estimator', 'POST', `/revisions/${ids.rev0}/lines`, [
      { section: 'Block works', description_en: '200 mm hollow block wall', description_ar: 'جدار بلوك مفرغ 200 مم', unit: 'm2', quantity: '1250.5', material_unit_cost: '38.75', labour_unit_cost: '17.4' },
      { section: 'Block works', description_en: 'Lintels', unit: 'LM', quantity: '333.333', material_unit_cost: '21.1234', labour_unit_cost: '9.0001' },
    ]);
    expect(added.status).toBe(201);
    expect(added.data.lines).toHaveLength(9);

    const params = { overhead_pct: '12.5', contingency_pct: '3', pricing_method: 'margin', target_margin_pct: '18', discount_type: 'percent', discount_value: '1.5', attention_contact_id: ids.contact } as const;
    const p = await s.call('estimator', 'PATCH', `/revisions/${ids.rev0}`, params);
    expect(p.status).toBe(200);

    // Database totals must equal the independent TypeScript engine, to the halala.
    const revRes = await s.call("estimator", "GET", `/revisions/${ids.rev0}`);
    expect(revRes.status).toBe(200);
    const rev = revRes.data;
    const expected = priceQuotation(rev.lines, { ...rev, ...params });
    for (const k of ['direct_cost', 'overhead_amount', 'contingency_amount', 'total_cost', 'target_price', 'price_factor', 'subtotal',
      'discount_amount', 'net_amount', 'vat_amount', 'total_amount', 'gross_profit', 'gross_margin_pct'] as const) {
      expect(rev[k], k).toBe(expected[k]);
    }
    rev.lines.forEach((l: any, i: number) => {
      expect(l.sell_rate).toBe(expected.lines[i].sell_rate);
      expect(l.sell_total).toBe(expected.lines[i].sell_total);
    });
    expect(Number(rev.vat_rate)).toBe(15);
    expect(Number(rev.total_amount)).toBeGreaterThan(0);

    // Calculated fields cannot be set by clients.
    const hack = await s.call('estimator', 'PATCH', `/revisions/${ids.rev0}`, { total_amount: '1' });
    expect(hack.status).toBe(400);

    const opp = await s.call('sales', 'GET', `/opportunities/${ids.opp}`);
    expect(opp.data.stage).toBe('estimation');
  });

  it('a draft PDF is watermarked and available', async () => {
    const pdf = await s.call('estimator', 'GET', `/revisions/${ids.rev0}/pdf`);
    expect(pdf.status).toBe(200);
    expect(pdf.headers.get('content-type')).toBe('application/pdf');
    expect(pdf.data.subarray(0, 5).toString()).toBe('%PDF-');
    expect(pdf.headers.get('content-disposition')).toContain('DRAFT');
  });

  it('stores the proposal in Reqaz format and validates payment milestones', async () => {
    const qp = await s.call('estimator', 'PATCH', `/quotations/${ids.quotation}`, { reference_prefix: 'RSH/JED271026-01' });
    expect(qp.status).toBe(200);
    const body = {
      project_name: 'Staff housing blocks A–C', project_location: 'Jeddah', client_rfp_reference: 'RSH-RFQ-88',
      signatory_id: (await s.call('gm', 'GET', '/me')).data.id, price_display: 'lump_sum_sections',
      cover_letter_en: 'We are pleased to submit our proposal.', executive_summary_en: 'Civil works for three blocks.',
      warranty_en: '12 months from handover.',
      schedule: [{ label: 'M1', description: 'Mobilisation', duration: '10 days' }, { label: 'M2', description: 'Structure', duration: '80 days' }],
      payment_milestones: [{ description: 'Advance payment', percent: 30 }, { description: 'On completion', percent: 60 }],
      compliance: [{ ref: '1.1', requirement: 'Saudi Building Code', status: 'Comply' }],
    };
    const p = await s.call('estimator', 'PATCH', `/revisions/${ids.rev0}`, body);
    expect(p.status).toBe(200);
    const rev = (await s.call('estimator', 'GET', `/revisions/${ids.rev0}`)).data;
    expect(rev.reference).toBe('RSH/JED271026-01R00');
    expect(rev.schedule).toHaveLength(2);
    expect(rev.payment_milestones[1].percent).toBe(60);
    expect(rev.price_display).toBe('lump_sum_sections');

    // Unknown keys inside the jsonb rows are refused.
    expect((await s.call('estimator', 'PATCH', `/revisions/${ids.rev0}`, { schedule: [{ label: 'x', description: 'y', duration: '1', price: 9 }] })).status).toBe(400);

    // Milestones must total 100% before the revision can go for approval.
    const bad = await s.call('estimator', 'POST', `/revisions/${ids.rev0}/transition`, { action: 'submit_for_approval' });
    expect(bad.status).toBe(422);
    expect(bad.data.message).toContain('100');
    expect((await s.call('estimator', 'PATCH', `/revisions/${ids.rev0}`, {
      payment_milestones: [{ description: 'Advance payment', percent: 30 }, { description: 'Progress', percent: 60 }, { description: 'Handover', percent: 10 }],
    })).status).toBe(200);

    const pdf = await s.call('estimator', 'GET', `/revisions/${ids.rev0}/pdf`);
    expect(pdf.status).toBe(200);
    expect(pdf.data.subarray(0, 5).toString()).toBe('%PDF-');
    expect(pdf.headers.get('content-disposition')).toContain('RSH-JED271026-01R00');
  });

  it('requires independent approval', async () => {
    const sub = await s.call('estimator', 'POST', `/revisions/${ids.rev0}/transition`, { action: 'submit_for_approval' });
    expect(sub.status).toBe(200);
    expect(sub.data.status).toBe('pending_approval');
    expect((await s.call('sales', 'GET', `/opportunities/${ids.opp}`)).data.stage).toBe('internal_review');

    // Locked while pending.
    const lines = (await s.call('estimator', 'GET', `/revisions/${ids.rev0}`)).data.lines;
    expect((await s.call('estimator', 'PATCH', `/lines/${lines[0].id}`, { quantity: '1' })).status).toBe(422);
    expect((await s.call('estimator', 'PATCH', `/revisions/${ids.rev0}`, { markup_pct: '50' })).status).toBe(422);

    // Estimators and sales cannot approve.
    expect((await s.call('estimator', 'POST', `/revisions/${ids.rev0}/transition`, { action: 'approve' })).status).toBe(403);
    expect((await s.call('sales', 'POST', `/revisions/${ids.rev0}/transition`, { action: 'approve' })).status).toBe(403);

    // GM rejects (comment required), estimator fixes and resubmits, GM approves.
    expect((await s.call('gm', 'POST', `/revisions/${ids.rev0}/transition`, { action: 'reject' })).status).toBe(422);
    const rej = await s.call('gm', 'POST', `/revisions/${ids.rev0}/transition`, { action: 'reject', comment: 'Increase contingency to 5%' });
    expect(rej.data.status).toBe('draft');
    expect((await s.call('estimator', 'PATCH', `/revisions/${ids.rev0}`, { contingency_pct: '5' })).status).toBe(200);
    expect((await s.call('estimator', 'POST', `/revisions/${ids.rev0}/transition`, { action: 'submit_for_approval' })).status).toBe(200);
    const ok = await s.call('gm', 'POST', `/revisions/${ids.rev0}/transition`, { action: 'approve', comment: 'Approved' });
    expect(ok.status).toBe(200);
    expect(ok.data.status).toBe('approved');
    expect(ok.data.approved_by).toBe((await s.call('gm', 'GET', '/me')).data.id);

    const rev = (await s.call('gm', 'GET', `/revisions/${ids.rev0}`)).data;
    expect(rev.approvals.map((a: any) => a.to_status)).toEqual(['pending_approval', 'draft', 'pending_approval', 'approved']);
    expect(rev.approvals[1].comment).toBe('Increase contingency to 5%');
  });

  it('the approver cannot approve their own quotation', async () => {
    const c = await dbClient();
    try {
      // GM prepares a quotation on a seeded opportunity and tries to approve it.
      const q = await s.call('gm', 'POST', '/quotations', { opportunity_id: '20000000-0000-4000-8000-000000000002', title: 'Self-approval check' });
      await s.call('gm', 'POST', `/revisions/${q.data.revision_id}/lines`, { description_en: 'Item', quantity: '1', material_unit_cost: '100' });
      expect((await s.call('gm', 'POST', `/revisions/${q.data.revision_id}/transition`, { action: 'submit_for_approval' })).status).toBe(200);
      const self = await s.call('gm', 'POST', `/revisions/${q.data.revision_id}/transition`, { action: 'approve' });
      expect(self.status).toBe(403);
      expect(self.data.message).toMatch(/someone other than its preparer/);
      const admin = await s.call('admin', 'POST', `/revisions/${q.data.revision_id}/transition`, { action: 'approve' });
      expect(admin.status).toBe(200);
    } finally { await c.end(); }
  });

  it('submission to the client archives the final PDF', async () => {
    expect((await s.call('estimator', 'POST', `/revisions/${ids.rev0}/transition`, { action: 'mark_submitted' })).status).toBe(403);
    const sub = await s.call('sales', 'POST', `/revisions/${ids.rev0}/transition`, { action: 'mark_submitted' });
    expect(sub.status).toBe(200);
    expect(sub.data.status).toBe('submitted');
    expect(sub.data.client_pdf_attachment_id).toBeTruthy();
    const file = await s.call('sales', 'GET', `/attachments/${sub.data.client_pdf_attachment_id}/download`);
    expect(file.status).toBe(200);
    expect(file.data.subarray(0, 5).toString()).toBe('%PDF-');
    // The archived client PDF cannot be deleted.
    expect((await s.call('admin', 'DELETE', `/attachments/${sub.data.client_pdf_attachment_id}`)).status).toBe(403);

    expect((await s.call('sales', 'GET', `/opportunities/${ids.opp}`)).data.stage).toBe('quotation_submitted');
    expect((await s.call('sales', 'GET', `/tenders/${ids.tender}`)).data.status).toBe('submitted');
  });

  it('a negotiated revision supersedes the earlier one', async () => {
    const r1 = await s.call('estimator', 'POST', `/quotations/${ids.quotation}/revisions`);
    expect(r1.status).toBe(201);
    ids.rev1 = r1.data.id;
    // Only one open revision at a time.
    expect((await s.call('estimator', 'POST', `/quotations/${ids.quotation}/revisions`)).status).toBe(422);

    const before = (await s.call('estimator', 'GET', `/revisions/${ids.rev0}`)).data;
    const r1d = (await s.call('estimator', 'GET', `/revisions/${ids.rev1}`)).data;
    expect(r1d.revision_no).toBe(1);
    expect(r1d.lines).toHaveLength(before.lines.length);
    expect(r1d.total_amount).toBe(before.total_amount);

    await s.call('estimator', 'PATCH', `/revisions/${ids.rev1}`, { discount_type: 'amount', discount_value: '25000' });
    await s.call('estimator', 'POST', `/revisions/${ids.rev1}/transition`, { action: 'submit_for_approval' });
    await s.call('gm', 'POST', `/revisions/${ids.rev1}/transition`, { action: 'approve' });
    expect((await s.call('sales', 'POST', `/revisions/${ids.rev1}/transition`, { action: 'mark_submitted' })).status).toBe(200);

    const q = (await s.call('sales', 'GET', `/quotations/${ids.quotation}`)).data;
    expect(q.revisions.map((r: any) => [r.revision_no, r.status])).toEqual([[1, 'submitted'], [0, 'superseded']]);
    // Rev 0 content is unchanged.
    expect((await s.call('sales', 'GET', `/revisions/${ids.rev0}`)).data.total_amount).toBe(before.total_amount);
  });

  it('awarding creates the contract and project from the approved revision', async () => {
    const c = await dbClient();
    const pm = await userId(c, 'pm');
    await c.end();
    const award = { project_manager_id: pm, start_date: '2026-12-01', target_completion_date: '2027-08-31', signed_date: '2026-11-20', retention_pct: '10', advance_payment_pct: '20' };

    expect((await s.call('sales', 'POST', `/revisions/${ids.rev1}/award`, award)).status).toBe(403);
    expect((await s.call('gm', 'POST', `/revisions/${ids.rev0}/award`, award)).status).toBe(422); // superseded
    expect((await s.call('gm', 'POST', `/revisions/${ids.rev1}/award`, { ...award, target_completion_date: '2026-01-01' })).status).toBe(422);

    const r = await s.call('gm', 'POST', `/revisions/${ids.rev1}/award`, award);
    expect(r.status).toBe(200);
    const rev = (await s.call('gm', 'GET', `/revisions/${ids.rev1}`)).data;
    expect(r.data.contract.number).toMatch(/^CON-\d{4}-\d{3}$/);
    expect(r.data.contract.original_value).toBe(rev.net_amount);
    expect(r.data.contract.retention_pct).toBe('10.00');
    expect(r.data.contract.awarded_snapshot.lines).toHaveLength(rev.lines.length);
    expect(Number(r.data.contract.awarded_snapshot.total_amount).toFixed(2)).toBe(rev.total_amount);
    expect(r.data.project.number).toMatch(/^PRJ-\d{4}-\d{3}$/);
    expect(r.data.project.approved_budget).toBe(rev.total_cost);
    expect(r.data.project.project_manager_id).toBe(pm);

    const opp = (await s.call('sales', 'GET', `/opportunities/${ids.opp}`)).data;
    expect(opp.stage).toBe('won');
    expect(opp.win_probability).toBe(100);
    expect((await s.call('sales', 'GET', `/tenders/${ids.tender}`)).data.status).toBe('won');
    const q = (await s.call('gm', 'GET', `/quotations/${ids.quotation}`)).data;
    expect(q.status).toBe('won');
    expect(q.contract.id).toBe(r.data.contract.id);

    // Closed records are frozen.
    expect((await s.call('estimator', 'POST', `/quotations/${ids.quotation}/revisions`)).status).toBe(422);
    expect((await s.call('sales', 'PATCH', `/opportunities/${ids.opp}`, { stage: 'negotiation' })).status).toBe(422);
    expect((await s.call('gm', 'POST', `/revisions/${ids.rev1}/award`, award)).status).toBe(422);
    expect((await s.call('pm', 'GET', '/projects')).data.some((p: any) => p.id === r.data.project.id)).toBe(true);
  });

  it('records an audit trail', async () => {
    const a = await s.call('admin', 'GET', `/audit?table=quotations&record_id=${ids.quotation}`);
    expect(a.status).toBe(200);
    expect(a.data.some((e: any) => e.action === 'EVENT' && e.note === 'Quotation awarded')).toBe(true);
    expect(a.data.some((e: any) => e.action === 'INSERT' && e.actor_name === 'Omar Estimator')).toBe(true);
    expect((await s.call('sales', 'GET', '/audit')).status).toBe(403);
  });

  it('a lost quotation closes the opportunity with a reason', async () => {
    const opp = '20000000-0000-4000-8000-000000000003';
    await s.call('sales', 'PATCH', `/opportunities/${opp}`, { stage: 'qualified' });
    const q = await s.call('estimator', 'POST', '/quotations', { opportunity_id: opp, title: 'Landscaping' });
    expect((await s.call('gm', 'POST', `/quotations/${q.data.id}/lost`, {})).status).toBe(400);
    const lost = await s.call('gm', 'POST', `/quotations/${q.data.id}/lost`, { reason: 'Lower price from competitor' });
    expect(lost.data.status).toBe('lost');
    const o = (await s.call('sales', 'GET', `/opportunities/${opp}`)).data;
    expect(o.stage).toBe('lost');
    expect(o.lost_reason).toBe('Lower price from competitor');
  });
});

describe('Leads and attachments', () => {
  it('converts a website lead into an opportunity once', async () => {
    const leads = (await s.call('sales', 'GET', '/leads?status=new')).data;
    const lead = leads.find((l: any) => l.external_id === 'wp-demo-1001');
    const conv = await s.call('sales', 'POST', `/leads/${lead.id}/convert`, {});
    expect(conv.status).toBe(200);
    expect(conv.data.source).toBe('website');
    expect(conv.data.prospect_email).toBe('reem@clinics.test');
    expect((await s.call('sales', 'POST', `/leads/${lead.id}/convert`, {})).status).toBe(422);
  });

  it('stores private attachments with permission checks', async () => {
    const form = new FormData();
    form.set('entity_type', 'tender');
    form.set('entity_id', ids.tender);
    form.set('file', new Blob([Buffer.from('%PDF-1.4 tender drawings')], { type: 'application/pdf' }), 'drawings.pdf');
    const up = await s.call('sales', 'POST', '/attachments', form);
    expect(up.status).toBe(201);
    expect(up.data.sha256).toHaveLength(64);

    const exe = new FormData();
    exe.set('entity_type', 'tender'); exe.set('entity_id', ids.tender);
    exe.set('file', new Blob([Buffer.from('MZ')], { type: 'application/x-msdownload' }), 'virus.exe');
    expect((await s.call('sales', 'POST', '/attachments', exe)).status).toBe(415);

    const siteForm = new FormData();
    siteForm.set('entity_type', 'tender'); siteForm.set('entity_id', ids.tender);
    siteForm.set('file', new Blob([Buffer.from('x')], { type: 'text/plain' }), 'x.txt');
    expect((await s.call('site', 'POST', '/attachments', siteForm)).status).toBe(404);

    const list = await s.call('estimator', 'GET', `/attachments?entity_type=tender&entity_id=${ids.tender}`);
    expect(list.data).toHaveLength(1);
    expect((await s.call('site', 'GET', `/attachments/${up.data.id}/download`)).status).toBe(404);
    const dl = await s.call('estimator', 'GET', `/attachments/${up.data.id}/download`);
    expect(dl.data.toString()).toBe('%PDF-1.4 tender drawings');

    expect((await s.call('pm', 'DELETE', `/attachments/${up.data.id}`)).status).toBe(403); // read-only on tenders
    expect((await s.call('sales', 'DELETE', `/attachments/${up.data.id}`)).status).toBe(204);
    expect((await s.call('sales', 'GET', `/attachments?entity_type=tender&entity_id=${ids.tender}`)).data).toHaveLength(0);
  });
});
