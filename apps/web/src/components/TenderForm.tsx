import { useTranslation } from 'react-i18next';
import { TENDER_STATUSES } from '@rms/shared';
import { fromLocalInput, toLocalInput } from '../lib/format';
import { Field, Input, Select, Textarea } from './ui';

export type TenderFormT = Record<string, any>;
export const EMPTY_TENDER: TenderFormT = { title: '', client_reference: '', issue_date: '', clarification_deadline: '', site_visit_at: '', submission_deadline: '', bid_bond_required: false, bid_bond_amount: '', notes: '', status: 'received' };

export function cleanTender(v: TenderFormT) {
  return {
    title: v.title, client_reference: v.client_reference ?? '', issue_date: v.issue_date ?? '', notes: v.notes ?? '', status: v.status,
    clarification_deadline: fromLocalInput(toLocalInput(v.clarification_deadline)) ?? '', site_visit_at: fromLocalInput(toLocalInput(v.site_visit_at)) ?? '',
    submission_deadline: fromLocalInput(toLocalInput(v.submission_deadline)), bid_bond_required: !!v.bid_bond_required,
    bid_bond_amount: v.bid_bond_amount === '' || v.bid_bond_amount === null ? null : String(v.bid_bond_amount),
  };
}

export function TenderFields({ v, set, showStatus }: { v: TenderFormT; set: (k: string, val: any) => void; showStatus?: boolean }) {
  const { t } = useTranslation();
  const f = (k: string) => ({ value: v[k] ?? '', onChange: (e: any) => set(k, e.target.value), name: k });
  const dt = (k: string) => ({ type: 'datetime-local', value: toLocalInput(v[k]), onChange: (e: any) => set(k, e.target.value ? new Date(e.target.value).toISOString() : ''), name: k });
  return (
    <div className="grid gap-3 sm:grid-cols-2">
      <Field label={t('common.title')} className="sm:col-span-2"><Input {...f('title')} /></Field>
      <Field label={t('tender.clientRef')}><Input {...f('client_reference')} /></Field>
      <Field label={t('tender.issueDate')}><Input type="date" {...f('issue_date')} /></Field>
      <Field label={t('tender.deadline')}><Input required {...dt('submission_deadline')} /></Field>
      <Field label={t('tender.clarification')}><Input {...dt('clarification_deadline')} /></Field>
      <Field label={t('tender.siteVisit')}><Input {...dt('site_visit_at')} /></Field>
      {showStatus && <Field label={t('common.status')}><Select {...f('status')}>{TENDER_STATUSES.map((s) => <option key={s} value={s}>{t(`tenderStatus.${s}`)}</option>)}</Select></Field>}
      <label className="flex items-center gap-2 self-end pb-2 text-sm"><input type="checkbox" checked={!!v.bid_bond_required} onChange={(e) => set('bid_bond_required', e.target.checked)} />{t('tender.bidBond')}</label>
      {v.bid_bond_required && <Field label={t('tender.bidBondAmount')}><Input type="number" min={0} step="0.01" {...f('bid_bond_amount')} /></Field>}
      <Field label={t('common.notes')} className="sm:col-span-2"><Textarea {...f('notes')} /></Field>
    </div>
  );
}
