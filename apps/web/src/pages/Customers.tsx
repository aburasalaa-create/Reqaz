import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Plus } from 'lucide-react';
import { PARTY_TYPES } from '@rms/shared';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { Badge, Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Select, Spinner, Textarea } from '../components/ui';

export type CustomerForm = Record<string, any>;
const EMPTY: CustomerForm = { party_type: 'company', name_en: '', name_ar: '', vat_number: '', cr_number: '', email: '', phone: '', website: '',
  building_number: '', street: '', district: '', city: '', postal_code: '', country: 'SA', payment_terms_days: 30, currency: 'SAR', notes: '' };

export function CustomerFields({ v, set }: { v: CustomerForm; set: (k: string, val: any) => void }) {
  const { t } = useTranslation();
  const f = (k: string) => ({ value: v[k] ?? '', onChange: (e: any) => set(k, e.target.value) });
  return (
    <div className="grid gap-3 sm:grid-cols-2">
      <Field label={t('common.name')}><Input required {...f('name_en')} name="name_en" /></Field>
      <Field label={t('common.nameAr')}><Input dir="rtl" {...f('name_ar')} name="name_ar" /></Field>
      <Field label={t('customer.partyType')}><Select {...f('party_type')}>{PARTY_TYPES.map((p) => <option key={p} value={p}>{t(`partyType.${p}`)}</option>)}</Select></Field>
      <Field label={t('customer.vat')} hint={t('customer.vatHint')}><Input inputMode="numeric" maxLength={15} {...f('vat_number')} name="vat_number" /></Field>
      <Field label={t('customer.cr')}><Input {...f('cr_number')} /></Field>
      <Field label={t('common.email')}><Input type="email" {...f('email')} name="email" /></Field>
      <Field label={t('common.phone')}><Input {...f('phone')} /></Field>
      <Field label={t('customer.website')}><Input {...f('website')} /></Field>
      <div className="sm:col-span-2 mt-1 text-xs font-semibold uppercase text-slate-400">{t('customer.address')}</div>
      <Field label={t('customer.building')}><Input {...f('building_number')} /></Field>
      <Field label={t('customer.street')}><Input {...f('street')} /></Field>
      <Field label={t('customer.district')}><Input {...f('district')} /></Field>
      <Field label={t('common.city')}><Input {...f('city')} name="city" /></Field>
      <Field label={t('customer.postal')}><Input {...f('postal_code')} /></Field>
      <Field label={t('customer.terms')}><Input type="number" min={0} max={365} {...f('payment_terms_days')} /></Field>
      <Field label={t('common.notes')} className="sm:col-span-2"><Textarea {...f('notes')} /></Field>
    </div>
  );
}

export function cleanCustomer(v: CustomerForm) {
  const out: CustomerForm = {};
  for (const [k, val] of Object.entries(v)) {
    if (!(k in EMPTY)) continue;
    out[k] = k === 'payment_terms_days' ? Number(val) : val;
  }
  return out;
}

export default function Customers() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [q, setQ] = useState('');
  const [active, setActive] = useState('true');
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<CustomerForm>(EMPTY);
  const { data, isLoading, error } = useQuery({ queryKey: ['customers', q, active], queryFn: () => api.get(`/customers${qs({ q, active })}`) });
  const create = useMutation({
    mutationFn: () => api.post('/customers', cleanCustomer(form)),
    onSuccess: (c) => { qc.invalidateQueries({ queryKey: ['customers'] }); setOpen(false); setForm(EMPTY); nav(`/customers/${c.id}`); },
  });

  return (
    <div>
      <PageHeader title={t('customer.title')} actions={can('customers.write') && <Button onClick={() => setOpen(true)}><Plus className="h-4 w-4" />{t('customer.new')}</Button>} />
      <Card bodyClass="p-0">
        <div className="flex flex-wrap gap-2 border-b p-3">
          <Input className="max-w-xs" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
          <Select className="max-w-[10rem]" value={active} onChange={(e) => setActive(e.target.value)}>
            <option value="true">{t('common.active')}</option><option value="false">{t('common.inactive')}</option><option value="all">{t('common.all')}</option>
          </Select>
        </div>
        {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : !data.length ? <Empty /> : (
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead className="bg-slate-50"><tr><th className="th">{t('common.code')}</th><th className="th">{t('common.name')}</th><th className="th">{t('customer.partyType')}</th><th className="th">{t('customer.vat')}</th><th className="th">{t('common.city')}</th><th className="th">{t('customer.opportunities')}</th></tr></thead>
              <tbody className="divide-y">
                {data.map((c: any) => (
                  <tr key={c.id} className="hover:bg-slate-50">
                    <td className="td font-mono text-xs">{c.code}</td>
                    <td className="td"><Link className="link" to={`/customers/${c.id}`}>{c.name_en}</Link>{c.name_ar && <div className="text-xs text-slate-500" dir="rtl">{c.name_ar}</div>}</td>
                    <td className="td"><Badge>{t(`partyType.${c.party_type}`)}</Badge></td>
                    <td className="td font-mono text-xs">{c.vat_number}</td>
                    <td className="td">{c.city}</td>
                    <td className="td">{c.opportunity_count}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
      <Modal open={open} onClose={() => setOpen(false)} title={t('customer.new')} wide
        footer={<><Button variant="secondary" onClick={() => setOpen(false)}>{t('common.cancel')}</Button><Button busy={create.isPending} onClick={() => create.mutate()}>{t('common.create')}</Button></>}>
        <ErrorBox error={create.error} />
        <CustomerFields v={form} set={(k, val) => setForm((f) => ({ ...f, [k]: val }))} />
      </Modal>
    </div>
  );
}
