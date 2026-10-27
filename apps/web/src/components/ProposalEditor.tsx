// Client-facing proposal content for a revision, in the layout of Reqaz's own proposals:
// cover details, cover letter, executive summary, scope, schedule, terms, payment milestones and compliance matrix.
import type { ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import { Plus, Trash2 } from 'lucide-react';
import { money } from '../lib/format';
import { Field, Input, Select, Textarea, cx } from './ui';

export const PROPOSAL_TEXT_FIELDS = ['subject', 'valid_until', 'attention_contact_id', 'project_name', 'project_location', 'client_rfp_reference', 'cc',
  'signatory_id', 'price_display', 'internal_notes',
  ...['cover_letter', 'executive_summary', 'scope', 'general_terms', 'exclusions', 'completion_period', 'warranty', 'payment_terms']
    .flatMap((k) => [`${k}_en`, `${k}_ar`])] as const;
export const PROPOSAL_ROW_FIELDS = ['schedule', 'payment_milestones', 'compliance'] as const;

type Col = { key: string; label: string; width?: string; type?: string; dir?: 'ltr' | 'rtl' | 'auto' };
type Terms = Record<string, any>;

/** Body for PATCH /revisions/:id — rows with no content are dropped. */
export function proposalBody(terms: Terms) {
  const body: Terms = {};
  for (const k of PROPOSAL_TEXT_FIELDS) body[k] = terms[k] ?? '';
  if (!body.price_display) body.price_display = 'itemised';
  body.schedule = (terms.schedule ?? []).filter((r: any) => r.label || r.description || r.duration);
  body.payment_milestones = (terms.payment_milestones ?? []).filter((r: any) => r.description || r.percent !== '')
    .map((r: any) => ({ description: r.description, percent: r.percent === '' ? 0 : Number(r.percent) }));
  body.compliance = (terms.compliance ?? []).filter((r: any) => r.ref || r.requirement || r.status);
  return body;
}

function RowsEditor({ rows, cols, onChange, disabled, blank, testid, footer }: {
  rows: any[]; cols: Col[]; onChange: (rows: any[]) => void; disabled: boolean; blank: any; testid: string; footer?: ReactNode;
}) {
  const { t } = useTranslation();
  const set = (i: number, k: string, v: string) => onChange(rows.map((r, j) => (j === i ? { ...r, [k]: v } : r)));
  return (
    <div className="overflow-x-auto rounded-md border">
      <table className="w-full text-sm" data-testid={testid}>
        <thead className="bg-slate-50"><tr>{cols.map((c) => <th key={c.key} className={cx('th', c.width)}>{c.label}</th>)}<th className="w-8" /></tr></thead>
        <tbody className="divide-y">
          {rows.map((r, i) => (
            <tr key={i}>
              {cols.map((c) => (
                <td key={c.key} className="px-1 py-0.5">
                  <input className={cx('w-full rounded border border-transparent bg-transparent px-1.5 py-1 hover:border-slate-300 focus:border-brand-500 focus:bg-white focus:outline-none', c.type === 'number' && 'text-end tabular-nums')}
                    type={c.type ?? 'text'} step="any" dir={c.dir ?? 'auto'} value={r[c.key] ?? ''} disabled={disabled} aria-label={c.label}
                    data-testid={`${testid}-${i}-${c.key}`} onChange={(e) => set(i, c.key, e.target.value)} />
                </td>
              ))}
              <td className="px-1">{!disabled && <button type="button" aria-label={t('common.delete')} className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600"
                onClick={() => onChange(rows.filter((_, j) => j !== i))}><Trash2 className="h-4 w-4" /></button>}</td>
            </tr>
          ))}
        </tbody>
        {footer}
      </table>
      {!disabled && <button type="button" data-testid={`${testid}-add`} className="flex w-full items-center justify-center gap-1 border-t py-1.5 text-xs text-brand-700 hover:bg-slate-50"
        onClick={() => onChange([...rows, { ...blank }])}><Plus className="h-3.5 w-3.5" />{t('proposal.addRow')}</button>}
    </div>
  );
}

export default function ProposalEditor({ terms, setTerms, editable, contacts, users, netAmount, currency }: {
  terms: Terms; setTerms: (t: Terms) => void; editable: boolean; contacts: any[]; users: any[]; netAmount: string | number; currency: string;
}) {
  const { t } = useTranslation();
  const set = (k: string, v: any) => setTerms({ ...terms, [k]: v });
  const text = (k: string, label: string) => <Field label={label}><Input dir="auto" name={k} value={terms[k] ?? ''} onChange={(e) => set(k, e.target.value)} /></Field>;
  const pair = (base: string, label: string, rows = 3) => (
    <div className="grid gap-3 sm:col-span-2 sm:grid-cols-2">
      <Field label={`${label} — ${t('quote.english')}`}><Textarea rows={rows} dir="ltr" name={`${base}_en`} value={terms[`${base}_en`] ?? ''} onChange={(e) => set(`${base}_en`, e.target.value)} /></Field>
      <Field label={`${label} — ${t('quote.arabic')}`}><Textarea rows={rows} dir="rtl" name={`${base}_ar`} value={terms[`${base}_ar`] ?? ''} onChange={(e) => set(`${base}_ar`, e.target.value)} /></Field>
    </div>
  );
  const heading = (s: string) => <h3 className="border-b pb-1 text-sm font-semibold text-slate-700 sm:col-span-2">{s}</h3>;
  const milestones: any[] = terms.payment_milestones ?? [];
  const msTotal = milestones.reduce((a, m) => a + (Number(m.percent) || 0), 0);
  const msOk = milestones.length === 0 || Math.abs(msTotal - 100) < 0.001;

  return (
    <fieldset disabled={!editable} className="grid gap-3 sm:grid-cols-2">
      {heading(t('proposal.cover'))}
      {text('subject', t('proposal.title'))}
      {text('project_name', t('proposal.projectName'))}
      {text('project_location', t('proposal.location'))}
      {text('client_rfp_reference', t('proposal.rfpRef'))}
      <Field label={t('proposal.referencePrefix')} hint={t('proposal.referenceHint')}>
        <Input dir="ltr" name="reference_prefix" value={terms.reference_prefix ?? ''} placeholder="ARS/RUH111026-01" onChange={(e) => set('reference_prefix', e.target.value)} />
      </Field>
      <div className="grid grid-cols-2 gap-3">
        <Field label={t('quote.validUntil')}><Input type="date" name="valid_until" value={terms.valid_until ?? ''} onChange={(e) => set('valid_until', e.target.value)} /></Field>
        <Field label={t('proposal.priceDisplay')}><Select name="price_display" value={terms.price_display || 'itemised'} onChange={(e) => set('price_display', e.target.value)}>
          <option value="itemised">{t('proposal.itemised')}</option><option value="lump_sum_sections">{t('proposal.lumpSum')}</option></Select></Field>
      </div>

      {heading(t('proposal.letter'))}
      <div className="grid grid-cols-2 gap-3">
        <Field label={t('quote.attention')}><Select name="attention_contact_id" value={terms.attention_contact_id ?? ''} onChange={(e) => set('attention_contact_id', e.target.value)}>
          <option value="">—</option>{contacts.map((c) => <option key={c.id} value={c.id}>{c.full_name}</option>)}</Select></Field>
        {text('cc', t('proposal.cc'))}
      </div>
      <Field label={t('proposal.signatory')} hint={t('proposal.signatoryHint')}><Select name="signatory_id" value={terms.signatory_id ?? ''} onChange={(e) => set('signatory_id', e.target.value)}>
        <option value="">{t('proposal.preparer')}</option>{users.map((u) => <option key={u.id} value={u.id}>{u.full_name}{u.job_title ? ` — ${u.job_title}` : ''}</option>)}</Select></Field>
      {pair('cover_letter', t('proposal.coverLetter'), 6)}

      {heading(t('proposal.summary'))}
      {pair('executive_summary', t('proposal.executiveSummary'))}
      {pair('scope', t('proposal.scopeList'), 5)}
      <div className="sm:col-span-2">
        <div className="label">{t('proposal.schedule')}</div>
        <RowsEditor testid="schedule" disabled={!editable} rows={terms.schedule ?? []} onChange={(v) => set('schedule', v)} blank={{ label: '', description: '', duration: '' }}
          cols={[{ key: 'label', label: t('proposal.stage'), width: 'w-36' }, { key: 'description', label: t('proposal.description') }, { key: 'duration', label: t('proposal.duration'), width: 'w-32' }]} />
      </div>
      {pair('general_terms', t('proposal.generalTerms'), 5)}
      {pair('exclusions', t('quote.exclusions'))}
      {pair('completion_period', t('proposal.delivery'), 2)}
      {pair('warranty', t('proposal.warranty'), 2)}
      {pair('payment_terms', t('quote.paymentTerms'), 2)}
      <div className="sm:col-span-2">
        <div className="label">{t('proposal.milestones')}</div>
        <RowsEditor testid="milestones" disabled={!editable} rows={milestones} onChange={(v) => set('payment_milestones', v)} blank={{ description: '', percent: '' }}
          cols={[{ key: 'description', label: t('proposal.description') }, { key: 'percent', label: '%', width: 'w-24', type: 'number', dir: 'ltr' }]}
          footer={milestones.length > 0 && <tfoot><tr className="border-t bg-slate-50 text-sm">
            <td className="px-3 py-1.5 font-medium">{t('common.total')} <span className="text-xs font-normal text-slate-500">({money(Number(netAmount) * msTotal / 100)} {currency})</span></td>
            <td className={cx('px-3 py-1.5 text-end font-semibold tabular-nums', msOk ? 'text-emerald-700' : 'text-red-600')} data-testid="milestones-total">{msTotal.toLocaleString('en-US', { maximumFractionDigits: 3 })}%</td><td /></tr></tfoot>} />
        {!msOk && <p className="mt-1 text-xs text-red-600">{t('proposal.milestonesMust100')}</p>}
      </div>

      {heading(t('proposal.compliance'))}
      <div className="sm:col-span-2">
        <RowsEditor testid="compliance" disabled={!editable} rows={terms.compliance ?? []} onChange={(v) => set('compliance', v)} blank={{ ref: '', requirement: '', status: 'Comply' }}
          cols={[{ key: 'ref', label: t('proposal.ref'), width: 'w-28' }, { key: 'requirement', label: t('proposal.requirement') }, { key: 'status', label: t('proposal.complianceStatus'), width: 'w-36' }]} />
      </div>

      <Field label={t('quote.internalNotes')} hint={t('proposal.internalHint')} className="sm:col-span-2"><Textarea dir="auto" name="internal_notes" value={terms.internal_notes ?? ''} onChange={(e) => set('internal_notes', e.target.value)} /></Field>
    </fieldset>
  );
}
