import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { LEAD_SOURCES } from '@rms/shared';
import { api } from '../lib/api';
import { Field, Input, Select, Textarea } from './ui';

export type OppForm = Record<string, any>;
export const EMPTY_OPP: OppForm = { title: '', customer_id: '', prospect_company: '', prospect_contact: '', prospect_email: '', prospect_phone: '',
  source: 'manual', service_type: '', location: '', description: '', expected_value: '', win_probability: 10, expected_close_date: '', owner_id: '' };

export function cleanOpp(v: OppForm) {
  const out: OppForm = {};
  for (const k of Object.keys(EMPTY_OPP)) {
    if (!(k in v)) continue;
    const val = v[k];
    if (k === 'expected_value') out[k] = val === '' || val === null ? null : String(val);
    else if (k === 'win_probability') out[k] = Number(val);
    else out[k] = val ?? '';
  }
  return out;
}

export function useLookups() {
  return useQuery({ queryKey: ['lookups'], queryFn: () => api.get('/lookups'), staleTime: 5 * 60_000 });
}

export function CustomerSelect({ value, onChange, name = 'customer_id' }: { value: string; onChange: (v: string) => void; name?: string }) {
  const { t } = useTranslation();
  const { data = [] } = useQuery({ queryKey: ['customers', 'select'], queryFn: () => api.get('/customers?limit=500') });
  return (
    <Select name={name} value={value ?? ''} onChange={(e) => onChange(e.target.value)}>
      <option value="">{t('common.select')}</option>
      {data.map((c: any) => <option key={c.id} value={c.id}>{c.name_en}{c.name_ar ? ` — ${c.name_ar}` : ''}</option>)}
    </Select>
  );
}

export function OpportunityFields({ v, set }: { v: OppForm; set: (k: string, val: any) => void }) {
  const { t } = useTranslation();
  const { data: lk } = useLookups();
  const f = (k: string) => ({ value: v[k] ?? '', onChange: (e: any) => set(k, e.target.value), name: k });
  return (
    <div className="grid gap-3 sm:grid-cols-2">
      <Field label={t('common.title')} className="sm:col-span-2"><Input required {...f('title')} /></Field>
      <Field label={t('common.customer')}><CustomerSelect value={v.customer_id} onChange={(x) => set('customer_id', x)} /></Field>
      <Field label={t('opp.source')}><Select {...f('source')}>{LEAD_SOURCES.map((s) => <option key={s} value={s}>{t(`source.${s}`)}</option>)}</Select></Field>
      {!v.customer_id && (<>
        <div className="sm:col-span-2 text-xs font-semibold uppercase text-slate-400">{t('opp.prospect')}</div>
        <Field label={t('opp.company')}><Input {...f('prospect_company')} /></Field>
        <Field label={t('opp.contact')}><Input {...f('prospect_contact')} /></Field>
        <Field label={t('common.email')}><Input type="email" {...f('prospect_email')} /></Field>
        <Field label={t('common.phone')}><Input {...f('prospect_phone')} /></Field>
      </>)}
      <Field label={t('opp.service')}><Input {...f('service_type')} /></Field>
      <Field label={t('opp.location')}><Input {...f('location')} /></Field>
      <Field label={`${t('opp.expectedValue')} (SAR)`}><Input type="number" min={0} step="0.01" {...f('expected_value')} /></Field>
      <Field label={t('opp.probability')}><Input type="number" min={0} max={100} {...f('win_probability')} /></Field>
      <Field label={t('opp.closeDate')}><Input type="date" {...f('expected_close_date')} /></Field>
      <Field label={t('common.owner')}><Select {...f('owner_id')}><option value="">{t('common.select')}</option>{lk?.users.map((u: any) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</Select></Field>
      <Field label={t('common.description')} className="sm:col-span-2"><Textarea {...f('description')} /></Field>
    </div>
  );
}
