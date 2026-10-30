import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Copy, FileDown, Lock, Plus, Trash2 } from 'lucide-react';
import { priceQuotation, type PricingParams } from '@rms/shared';
import { api } from '../lib/api';
import { useAuth } from '../lib/auth';
import { date, dateTime, money, num } from '../lib/format';
import Attachments from '../components/Attachments';
import { useLookups } from '../components/OpportunityForm';
import ProposalEditor, { PROPOSAL_ROW_FIELDS, PROPOSAL_TEXT_FIELDS, proposalBody } from '../components/ProposalEditor';
import { Badge, Button, Card, ErrorBox, Field, Input, Modal, PageHeader, Select, Spinner, STATUS_TONE, Textarea, cx, useToast } from '../components/ui';

const COST_FIELDS = ['material_unit_cost', 'labour_unit_cost', 'equipment_unit_cost', 'subcontract_unit_cost', 'other_unit_cost'] as const;
const COST_LABEL: Record<(typeof COST_FIELDS)[number], string> = {
  material_unit_cost: 'quote.material', labour_unit_cost: 'quote.labour', equipment_unit_cost: 'quote.equipment',
  subcontract_unit_cost: 'quote.subcontract', other_unit_cost: 'quote.other',
};
const LINE_FIELDS = ['section', 'item_code', 'description_en', 'description_ar', 'unit', 'quantity', 'manual_rate', ...COST_FIELDS] as const;
const PARAM_FIELDS = ['overhead_pct', 'contingency_pct', 'pricing_method', 'markup_pct', 'target_margin_pct', 'discount_type', 'discount_value', 'vat_code'] as const;

export default function QuotationDetail() {
  const { id } = useParams();
  const [sp, setSp] = useSearchParams();
  const { t } = useTranslation();
  const { can, me } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const { data: lk } = useLookups();
  const quote = useQuery({ queryKey: ['quotation', id], queryFn: () => api.get(`/quotations/${id}`) });
  const revId = sp.get('rev') ?? quote.data?.revisions?.[0]?.id;
  const rev = useQuery({ queryKey: ['revision', revId], queryFn: () => api.get(`/revisions/${revId}`), enabled: !!revId });
  const boqs = useQuery({ queryKey: ['boq-templates'], queryFn: () => api.get('/boq-templates'), enabled: can('estimation.read') });

  const [rows, setRows] = useState<any[]>([]);
  const [params, setParams] = useState<Record<string, any>>({});
  const [terms, setTerms] = useState<Record<string, any>>({});
  const [reject, setReject] = useState<string | null>(null);
  const [award, setAward] = useState<any>(null);
  const [lost, setLost] = useState<string | null>(null);
  const [showCostsPref, setShowCosts] = useState<boolean | null>(null);

  // Fields the user is editing right now; server refreshes must not overwrite them.
  const dirty = useRef(new Set<string>());
  const lastRev = useRef<string | null>(null);
  useEffect(() => {
    if (!rev.data) return;
    const sameRev = lastRev.current === rev.data.id;
    lastRev.current = rev.data.id;
    setRows((local) => rev.data.lines.map((l: any) => {
      const mine = sameRev ? local.find((x) => x.id === l.id) : undefined;
      const merged = { ...l };
      if (mine) for (const f of LINE_FIELDS) if (dirty.current.has(`${l.id}:${f}`)) merged[f] = mine[f];
      return merged;
    }));
    setParams((local) => Object.fromEntries(PARAM_FIELDS.map((k) => [k, sameRev && dirty.current.has(`param:${k}`) ? local[k] : rev.data[k]])));
    if (!sameRev) setTerms({
      ...Object.fromEntries(PROPOSAL_TEXT_FIELDS.map((k) => [k, rev.data[k] ?? ''])),
      ...Object.fromEntries(PROPOSAL_ROW_FIELDS.map((k) => [k, rev.data[k] ?? []])),
      reference_prefix: quote.data?.reference_prefix ?? '',
    });
  }, [rev.data]);

  const refresh = async () => {
    await Promise.all([qc.invalidateQueries({ queryKey: ['revision', revId] }), qc.invalidateQueries({ queryKey: ['quotation', id] })]);
  };
  const onErr = (e: Error) => { toast(e.message, 'error'); void refresh(); };

  const patchLine = useMutation({ mutationFn: ({ lid, body }: { lid: string; body: any }) => api.patch(`/lines/${lid}`, body), onSuccess: refresh, onError: onErr });
  const addLine = useMutation({ mutationFn: () => api.post(`/revisions/${revId}/lines`, { description_en: 'New item', unit: 'LS', quantity: '1', section: rows.at(-1)?.section ?? '' }), onSuccess: refresh, onError: onErr });
  const delLine = useMutation({ mutationFn: (lid: string) => api.del(`/lines/${lid}`), onSuccess: refresh, onError: onErr });
  const applyBoq = useMutation({ mutationFn: (tid: string) => api.post(`/revisions/${revId}/apply-boq-template`, { template_id: tid }), onSuccess: refresh, onError: onErr });
  const patchRev = useMutation({ mutationFn: (body: any) => api.patch(`/revisions/${revId}`, body), onSuccess: refresh, onError: onErr });
  const transition = useMutation({
    mutationFn: (b: { action: string; comment?: string }) => api.post(`/revisions/${revId}/transition`, b),
    onSuccess: () => { void refresh(); qc.invalidateQueries({ queryKey: ['dashboard'] }); },
    onError: onErr,
  });
  const newRev = useMutation({ mutationFn: () => api.post(`/quotations/${id}/revisions`), onSuccess: async (r) => { await refresh(); setSp({ rev: r.id }); }, onError: onErr });
  const doAward = useMutation({ mutationFn: () => api.post(`/revisions/${revId}/award`, award), onSuccess: () => { setAward(null); void refresh(); toast(t('quote.awarded')); } });
  const doLost = useMutation({ mutationFn: () => api.post(`/quotations/${id}/lost`, { reason: lost }), onSuccess: () => { setLost(null); void refresh(); }, onError: onErr });

  const preview = useMemo(() => {
    if (!rev.data) return null;
    try {
      return priceQuotation(rows, { ...(rev.data as PricingParams), ...params, vat_rate: lk?.vat_codes.find((v: any) => v.code === params.vat_code)?.rate ?? rev.data.vat_rate } as PricingParams);
    } catch { return null; }
  }, [rows, params, rev.data, lk]);

  if (quote.isLoading || rev.isLoading) return <Spinner />;
  if (quote.error) return <ErrorBox error={quote.error} />;
  if (rev.error) return <ErrorBox error={rev.error} />;
  const q = quote.data;
  const r = rev.data;
  if (!r) return <Spinner />;
  const latest = q.revisions[0];
  const draft = r.status === 'draft';
  const editable = draft && can('quotations.write') && q.status === 'open';
  const isLatest = latest.id === r.id;
  const cur = q.currency;
  // Simple view by default: description, quantity and a typed rate. Costing opens automatically when costs exist.
  const showCosts = showCostsPref ?? Number(r.direct_cost) > 0;

  const commitLine = (row: any, field: string) => {
    dirty.current.delete(`${row.id}:${field}`);
    const orig = r.lines.find((l: any) => l.id === row.id);
    if (!orig || String(orig[field] ?? '') === String(row[field] ?? '')) return;
    if (field === 'description_en' && !String(row[field]).trim()) return toast(t('common.required'), 'error');
    patchLine.mutate({ lid: row.id, body: { [field]: row[field] } });
  };
  const setRow = (i: number, field: string, v: string) => {
    dirty.current.add(`${rows[i].id}:${field}`);
    setRows((rs) => rs.map((x, j) => (j === i ? { ...x, [field]: v } : x)));
  };
  const editParam = (k: string, v: any) => {
    dirty.current.add(`param:${k}`);
    setParams((p) => ({ ...p, [k]: v }));
  };
  const commitParam = (k: string, v: any) => {
    dirty.current.delete(`param:${k}`);
    setParams((p) => ({ ...p, [k]: v }));
    if (String(r[k] ?? '') !== String(v ?? '')) patchRev.mutate({ [k]: v });
  };
  const saveTerms = async () => {
    try {
      if ((terms.reference_prefix ?? '') !== (q.reference_prefix ?? '')) await api.patch(`/quotations/${q.id}`, { reference_prefix: terms.reference_prefix });
      await patchRev.mutateAsync(proposalBody(terms));
      toast(t('common.saved'));
    } catch { /* onError already reported it */ }
  };
  const pdf = (lang: string) => api.openFile(`/revisions/${r.id}/pdf?lang=${lang}`).catch((e) => toast(e.message, 'error'));

  const canApprove = can('quotations.approve') && r.status === 'pending_approval';
  // With self-approval allowed, an approver finishes a draft in one click (submitted and approved, both recorded).
  const canQuickApprove = editable && can('quotations.approve') && !!me?.allow_self_approval;
  const quickApprove = async () => {
    try {
      await api.post(`/revisions/${revId}/transition`, { action: 'submit_for_approval' });
      await transition.mutateAsync({ action: 'approve' });
    } catch (e) { onErr(e as Error); }
  };
  const canWithdraw = r.status === 'pending_approval' && r.submitted_for_approval_by === me?.id;
  const P = preview ?? r;

  return (
    <div>
      <PageHeader
        title={<span className="flex flex-wrap items-center gap-2">{q.number} — {q.title}<Badge tone={STATUS_TONE[q.status]}>{t(`quoteStatus.${q.status}`)}</Badge></span>}
        subtitle={<><Link className="link" to={`/customers/${q.customer_id}`}>{q.customer_name}</Link> · <Link className="link" to={`/opportunities/${q.opportunity_id}`}>{q.opportunity_number}</Link>{q.tender_number && <> · {q.tender_number}</>}
          {q.contract && <> · {t('quote.contract')} {q.contract.number}{q.project && <> · {t('quote.project')} {q.project.number}</>}</>}</>}
        actions={<>
          <div className="flex overflow-hidden rounded-md border">
            <button className="inline-flex items-center gap-1 bg-white px-2.5 py-1.5 text-sm hover:bg-slate-50" onClick={() => pdf('bilingual')} data-testid="pdf-bilingual"><FileDown className="h-4 w-4" />{t('quote.pdfBilingual')}</button>
            <button className="border-s bg-white px-2 py-1.5 text-sm hover:bg-slate-50" onClick={() => pdf('en')}>EN</button>
            <button className="border-s bg-white px-2 py-1.5 text-sm hover:bg-slate-50" onClick={() => pdf('ar')}>ع</button>
          </div>
          {can('quotations.write') && q.status === 'open' && ['approved', 'submitted'].includes(latest.status) && <Button variant="secondary" busy={newRev.isPending} onClick={() => newRev.mutate()}><Copy className="h-4 w-4" />{t('quote.newRevision')}</Button>}
          {can('quotations.award') && q.status === 'open' && <Button variant="secondary" onClick={() => setLost('')}>{t('quote.markLost')}</Button>}
        </>} />

      {/* Revision tabs */}
      <div className="mb-3 flex flex-wrap gap-1 border-b">
        {q.revisions.map((x: any) => (
          <button key={x.id} onClick={() => setSp({ rev: x.id })} data-testid={`rev-tab-${x.revision_no}`}
            className={cx('-mb-px flex items-center gap-1.5 border-b-2 px-3 py-2 text-sm', x.id === r.id ? 'border-brand-700 font-medium text-brand-800' : 'border-transparent text-slate-500 hover:text-slate-700')}>
            {t('quote.revision')} {x.revision_no}<Badge tone={STATUS_TONE[x.status]}>{t(`revStatus.${x.status}`)}</Badge>
          </button>
        ))}
      </div>

      {/* Workflow bar */}
      <div className="mb-4 flex flex-wrap items-center justify-between gap-2 rounded-lg border bg-white px-4 py-2.5">
        <div className="flex items-center gap-2 text-sm text-slate-600">
          <span data-testid="rev-status"><Badge tone={STATUS_TONE[r.status]}>{t(`revStatus.${r.status}`)}</Badge></span>
          {!draft && <span className="inline-flex items-center gap-1 text-xs text-slate-500"><Lock className="h-3 w-3" />{t('quote.locked')}</span>}
          {r.approved_by_name && <span className="text-xs">{t('quote.approve')}: {r.approved_by_name} · {dateTime(r.approved_at)}</span>}
        </div>
        <div className="flex flex-wrap gap-2">
          {canQuickApprove && <Button variant="success" onClick={quickApprove} busy={transition.isPending} data-testid="quick-approve">{t('quote.approve')}</Button>}
          {editable && <Button variant={canQuickApprove ? 'secondary' : undefined} onClick={() => transition.mutate({ action: 'submit_for_approval' })} busy={transition.isPending}>{t('quote.submitForApproval')}</Button>}
          {canWithdraw && <Button variant="secondary" onClick={() => transition.mutate({ action: 'withdraw' })}>{t('quote.withdraw')}</Button>}
          {canApprove && <><Button variant="danger" onClick={() => setReject('')}>{t('quote.reject')}</Button><Button variant="success" busy={transition.isPending} onClick={() => transition.mutate({ action: 'approve' })}>{t('quote.approve')}</Button></>}
          {r.status === 'approved' && isLatest && can('quotations.submit') && <Button busy={transition.isPending} onClick={() => transition.mutate({ action: 'mark_submitted' })}>{t('quote.markSubmitted')}</Button>}
          {r.status === 'submitted' && can('quotations.award') && q.status === 'open' && <Button variant="success" onClick={() => setAward({ project_name: q.title, project_manager_id: '', start_date: '', target_completion_date: '', signed_date: '', retention_pct: '0', advance_payment_pct: '0' })}>{t('quote.award')}</Button>}
          {r.client_pdf_attachment_id && <Button variant="secondary" onClick={() => api.openFile(`/attachments/${r.client_pdf_attachment_id}/download`, `${r.reference.replace(/[^A-Za-z0-9._-]+/g, "-")}.pdf`)}><FileDown className="h-4 w-4" />{t('quote.clientPdf')}</Button>}
        </div>
      </div>

      <div className="grid gap-4 2xl:grid-cols-[1fr_22rem]">
        <div className="min-w-0 space-y-4">
          <Card title={t('quote.lines')} bodyClass="p-0" actions={<>
            <label className="flex items-center gap-1 text-xs text-slate-500"><input type="checkbox" data-testid="show-costs" checked={showCosts} onChange={(e) => setShowCosts(e.target.checked)} />{t('quote.costBreakdown')}</label>
            {editable && boqs.data?.length > 0 && <Select className="w-52" value="" onChange={(e) => e.target.value && applyBoq.mutate(e.target.value)} aria-label={t('quote.boqTemplate')}>
              <option value="">{t('quote.boqTemplate')}…</option>{boqs.data.filter((b: any) => b.is_active).map((b: any) => <option key={b.id} value={b.id}>{b.name} ({b.item_count})</option>)}</Select>}
            {editable && <Button variant="secondary" busy={addLine.isPending} onClick={() => addLine.mutate()} data-testid="add-line"><Plus className="h-4 w-4" />{t('quote.addLine')}</Button>}
          </>}>
            <div className="overflow-x-auto">
              <table className={cx('w-full text-sm', showCosts ? 'min-w-[900px]' : 'min-w-[560px]')}>
                <thead className="bg-slate-50">
                  <tr>
                    {showCosts && <><th className="th w-24">{t('quote.section')}</th><th className="th w-14">{t('quote.item')}</th></>}<th className="th min-w-[14rem]">{t('quote.descEn')} / {t('quote.descAr')}</th>
                    <th className="th w-16">{t('quote.unit')}</th><th className="th w-20 text-end">{t('quote.qty')}</th>
                    {showCosts && COST_FIELDS.map((f) => <th key={f} className="th w-24 text-end">{t(COST_LABEL[f])}</th>)}
                    {showCosts && <th className="th w-24 text-end">{t('quote.costTotal')}</th>}
                    <th className="th w-28 text-end">{t('quote.sellRate')}</th><th className="th w-28 text-end">{t('quote.sellTotal')}</th>{editable && <th className="w-8" />}
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {rows.map((l, i) => {
                    const pl = preview?.lines[i];
                    const cell = (f: string, cls = '', type = 'text') => editable
                      ? <input data-testid={`line-${i}-${f}`} type={type} step="any" className={cx('w-full rounded border border-transparent bg-transparent px-1 py-0.5 hover:border-slate-300 focus:border-brand-500 focus:bg-white focus:outline-none', cls)}
                          value={l[f] ?? ''} onChange={(e) => setRow(i, f, e.target.value)} onBlur={() => commitLine(l, f)} dir={f === 'description_ar' ? 'rtl' : undefined} placeholder={f === 'description_ar' ? t('quote.arabic') : ''} />
                      : <span className={cx('block px-1', cls)} dir={f === 'description_ar' ? 'rtl' : undefined}>{['quantity', ...COST_FIELDS].includes(f) ? num(l[f], 4) : l[f]}</span>;
                    return (
                      <tr key={l.id} className="align-top">
                        {showCosts && <><td className="px-2 py-1">{cell('section')}</td>
                        <td className="px-2 py-1">{cell('item_code')}</td></>}
                        <td className="px-2 py-1">{cell('description_en')}{cell('description_ar', 'text-slate-600')}</td>
                        <td className="px-2 py-1">{cell('unit')}</td>
                        <td className="px-2 py-1">{cell('quantity', 'text-end tabular-nums', 'number')}</td>
                        {showCosts && COST_FIELDS.map((f) => <td key={f} className="bg-amber-50/40 px-2 py-1">{cell(f, 'text-end tabular-nums', 'number')}</td>)}
                        {showCosts && <td className="bg-amber-50/40 px-2 py-1 text-end tabular-nums text-slate-600">{money(pl?.cost_total ?? l.cost_total)}</td>}
                        <td className="px-2 py-1 text-end tabular-nums">{editable
                          ? <input data-testid={`line-${i}-manual_rate`} type="number" step="any" min="0" className="w-full rounded border border-slate-200 bg-white px-1 py-0.5 text-end tabular-nums focus:border-brand-500 focus:outline-none"
                              value={l.manual_rate ?? ''} placeholder={money(pl?.sell_rate ?? l.sell_rate)} title={t('quote.rateHint')}
                              onChange={(e) => setRow(i, 'manual_rate', e.target.value)} onBlur={() => commitLine(l, 'manual_rate')} />
                          : money(pl?.sell_rate ?? l.sell_rate)}</td>
                        <td className="px-2 py-1 text-end font-medium tabular-nums" data-testid={`line-${i}-total`}>{money(pl?.sell_total ?? l.sell_total)}</td>
                        {editable && <td className="px-1 py-1"><button aria-label={t('common.delete')} className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600" onClick={() => delLine.mutate(l.id)}><Trash2 className="h-4 w-4" /></button></td>}
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            {showCosts && <div className="border-t px-4 py-1.5 text-xs text-amber-700">{t('quote.estimateOnly')}</div>}
          </Card>

          <Card title={t('proposal.heading')} actions={editable && <Button busy={patchRev.isPending} onClick={saveTerms} data-testid="save-proposal">{t('common.save')}</Button>}>
            <ProposalEditor terms={terms} setTerms={setTerms} editable={editable} contacts={r.contacts} users={lk?.users ?? []} netAmount={P.net_amount} currency={q.currency} />
          </Card>
          <Attachments entityType="quotation" entityId={q.id} canWrite={can('quotations.write')} />
        </div>

        <div className="space-y-4">
          <Card title={t('quote.pricing')}>
            <fieldset disabled={!editable} className="grid grid-cols-2 gap-3">
              {showCosts && <>
              <Field label={t('quote.overhead')}><Input type="number" step="any" name="overhead_pct" value={params.overhead_pct ?? ''} onChange={(e) => editParam('overhead_pct', e.target.value)} onBlur={() => commitParam('overhead_pct', params.overhead_pct)} /></Field>
              <Field label={t('quote.contingency')}><Input type="number" step="any" name="contingency_pct" value={params.contingency_pct ?? ''} onChange={(e) => editParam('contingency_pct', e.target.value)} onBlur={() => commitParam('contingency_pct', params.contingency_pct)} /></Field>
              <Field label={t('quote.method')} className="col-span-2"><Select name="pricing_method" value={params.pricing_method ?? 'markup'} onChange={(e) => commitParam('pricing_method', e.target.value)}>
                <option value="markup">{t('quote.methodMarkup')}</option><option value="margin">{t('quote.methodMargin')}</option></Select></Field>
              {params.pricing_method === 'margin'
                ? <Field label={t('quote.margin')}><Input type="number" step="any" name="target_margin_pct" value={params.target_margin_pct ?? ''} onChange={(e) => editParam('target_margin_pct', e.target.value)} onBlur={() => commitParam('target_margin_pct', params.target_margin_pct)} /></Field>
                : <Field label={t('quote.markup')}><Input type="number" step="any" name="markup_pct" value={params.markup_pct ?? ''} onChange={(e) => editParam('markup_pct', e.target.value)} onBlur={() => commitParam('markup_pct', params.markup_pct)} /></Field>}
              </>}
              <Field label={t('quote.vat')}><Select name="vat_code" value={params.vat_code ?? 'S15'} onChange={(e) => commitParam('vat_code', e.target.value)}>
                {lk?.vat_codes.map((v: any) => <option key={v.code} value={v.code}>{v.name_en}</option>)}</Select></Field>
              <Field label={t('quote.discountType')}><Select name="discount_type" value={params.discount_type ?? 'none'} onChange={(e) => commitParam('discount_type', e.target.value)}>
                <option value="none">{t('quote.discountNone')}</option><option value="percent">{t('quote.discountPercent')}</option><option value="amount">{t('quote.discountAmount')}</option></Select></Field>
              {params.discount_type !== 'none' && <Field label={t('quote.discount')}><Input type="number" step="any" name="discount_value" value={params.discount_value ?? ''} onChange={(e) => editParam('discount_value', e.target.value)} onBlur={() => commitParam('discount_value', params.discount_value)} /></Field>}
            </fieldset>
          </Card>
          <Card title={t('common.total')}>
            <dl className="space-y-1 text-sm" data-testid="totals">
              {showCosts && <>{([['directCost', P.direct_cost], ['overheadAmt', P.overhead_amount], ['contingencyAmt', P.contingency_amount], ['totalCost', P.total_cost]] as const).map(([k, v]) => (
                <div key={k} className="flex justify-between text-slate-500"><dt>{t(`quote.${k}`)}</dt><dd className="tabular-nums">{money(v)}</dd></div>
              ))}
              <div className="my-2 border-t" /></>}
              <div className="flex justify-between"><dt>{t('quote.subtotal')}</dt><dd className="tabular-nums">{money(P.subtotal)}</dd></div>
              {Number(P.discount_amount) > 0 && <div className="flex justify-between"><dt>{t('quote.discount')}</dt><dd className="tabular-nums">({money(P.discount_amount)})</dd></div>}
              <div className="flex justify-between"><dt>{t('quote.net')}</dt><dd className="tabular-nums" data-testid="net">{money(P.net_amount)}</dd></div>
              <div className="flex justify-between"><dt>{t('quote.vatAmt')}</dt><dd className="tabular-nums" data-testid="vat">{money(P.vat_amount)}</dd></div>
              <div className="flex justify-between border-t pt-1 text-base font-semibold"><dt>{t('quote.totalInclVat')}</dt><dd className="tabular-nums" data-testid="grand-total">{cur} {money(P.total_amount)}</dd></div>
              {Number(P.total_cost) > 0 && <div className="mt-2 flex justify-between rounded bg-amber-50 px-2 py-1 text-amber-800"><dt>{t('quote.grossProfit')}</dt><dd className="tabular-nums">{money(P.gross_profit)} {P.gross_margin_pct !== null && `(${P.gross_margin_pct}%)`}</dd></div>}
            </dl>
            {editable && <p className="mt-2 text-xs text-slate-400">{t('quote.livePreview')}</p>}
          </Card>
          <Card title={t('quote.approvals')} bodyClass="p-0">
            <ul className="divide-y">{r.approvals.map((a: any) => (
              <li key={a.id} className="px-4 py-2 text-xs"><Badge tone={STATUS_TONE[a.to_status]}>{t(`revStatus.${a.to_status}`)}</Badge> <span className="text-slate-600">{a.actor_name}</span>
                <span className="block text-slate-400">{dateTime(a.created_at)}</span>{a.comment && <span className="mt-0.5 block text-slate-700">“{a.comment}”</span>}</li>
            ))}</ul>
            {!r.approvals.length && <p className="px-4 py-3 text-xs text-slate-400">—</p>}
          </Card>
          <p className="text-xs text-slate-400">{t('quote.validUntil')}: {date(r.valid_until)} · {r.prepared_by_name}</p>
        </div>
      </div>

      <Modal open={reject !== null} onClose={() => setReject(null)} title={t('quote.reject')}
        footer={<><Button variant="secondary" onClick={() => setReject(null)}>{t('common.cancel')}</Button><Button variant="danger" disabled={!reject?.trim()} onClick={() => { transition.mutate({ action: 'reject', comment: reject! }); setReject(null); }}>{t('quote.reject')}</Button></>}>
        <Field label={t('quote.rejectComment')}><Textarea name="reject_comment" value={reject ?? ''} onChange={(e) => setReject(e.target.value)} /></Field>
      </Modal>
      <Modal open={lost !== null} onClose={() => setLost(null)} title={t('quote.markLost')}
        footer={<><Button variant="secondary" onClick={() => setLost(null)}>{t('common.cancel')}</Button><Button variant="danger" disabled={!lost?.trim()} busy={doLost.isPending} onClick={() => doLost.mutate()}>{t('common.confirm')}</Button></>}>
        <Field label={t('common.reason')}><Textarea value={lost ?? ''} onChange={(e) => setLost(e.target.value)} /></Field>
      </Modal>
      <Modal open={!!award} onClose={() => setAward(null)} title={t('quote.award')}
        footer={<><Button variant="secondary" onClick={() => setAward(null)}>{t('common.cancel')}</Button><Button variant="success" busy={doAward.isPending} onClick={() => doAward.mutate()}>{t('common.confirm')}</Button></>}>
        <ErrorBox error={doAward.error} />
        {award && <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('quote.projectName')} className="sm:col-span-2"><Input value={award.project_name} onChange={(e) => setAward({ ...award, project_name: e.target.value })} /></Field>
          <Field label={t('quote.projectManager')} className="sm:col-span-2"><Select name="project_manager_id" value={award.project_manager_id} onChange={(e) => setAward({ ...award, project_manager_id: e.target.value })}>
            <option value="">{t('common.select')}</option>{lk?.users.map((u: any) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</Select></Field>
          <Field label={t('quote.startDate')}><Input type="date" name="start_date" value={award.start_date} onChange={(e) => setAward({ ...award, start_date: e.target.value })} /></Field>
          <Field label={t('quote.targetDate')}><Input type="date" name="target_completion_date" value={award.target_completion_date} onChange={(e) => setAward({ ...award, target_completion_date: e.target.value })} /></Field>
          <Field label={t('quote.signedDate')}><Input type="date" value={award.signed_date} onChange={(e) => setAward({ ...award, signed_date: e.target.value })} /></Field>
          <div />
          <Field label={t('quote.retention')}><Input type="number" step="any" value={award.retention_pct} onChange={(e) => setAward({ ...award, retention_pct: e.target.value })} /></Field>
          <Field label={t('quote.advance')}><Input type="number" step="any" value={award.advance_payment_pct} onChange={(e) => setAward({ ...award, advance_payment_pct: e.target.value })} /></Field>
          <div className="sm:col-span-2 rounded bg-slate-50 p-2 text-sm">{t('project.value')}: <strong>{money(r.net_amount, cur)}</strong> · {t('project.budget')}: <strong>{money(r.total_cost, cur)}</strong></div>
        </div>}
      </Modal>
    </div>
  );
}
