import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Plus, Star, Trash2 } from 'lucide-react';
import { api } from '../lib/api';
import { useAuth } from '../lib/auth';
import { money } from '../lib/format';
import Attachments from '../components/Attachments';
import { Badge, Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Spinner, STATUS_TONE, useToast } from '../components/ui';
import { CustomerFields, cleanCustomer, type CustomerForm } from './Customers';

export default function CustomerDetail() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const { data, isLoading, error } = useQuery({ queryKey: ['customer', id], queryFn: () => api.get(`/customers/${id}`) });
  const [form, setForm] = useState<CustomerForm>({});
  const [contactOpen, setContactOpen] = useState(false);
  const [contact, setContact] = useState({ full_name: '', position: '', email: '', phone: '', is_primary: false });
  useEffect(() => { if (data) setForm(data); }, [data]);
  const refresh = () => qc.invalidateQueries({ queryKey: ['customer', id] });

  const save = useMutation({ mutationFn: () => api.patch(`/customers/${id}`, cleanCustomer(form)), onSuccess: () => { refresh(); toast(t('common.saved')); }, onError: (e: Error) => toast(e.message, 'error') });
  const toggle = useMutation({ mutationFn: () => api.patch(`/customers/${id}`, { is_active: !data.is_active }), onSuccess: refresh });
  const addContact = useMutation({ mutationFn: () => api.post(`/customers/${id}/contacts`, contact), onSuccess: () => { refresh(); setContactOpen(false); setContact({ full_name: '', position: '', email: '', phone: '', is_primary: false }); } });
  const delContact = useMutation({ mutationFn: (cid: string) => api.del(`/contacts/${cid}`), onSuccess: refresh, onError: (e: Error) => toast(e.message, 'error') });
  const primary = useMutation({ mutationFn: (cid: string) => api.patch(`/contacts/${cid}`, { is_primary: true }), onSuccess: refresh });

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const w = can('customers.write');

  return (
    <div>
      <PageHeader title={<>{data.name_en} {!data.is_active && <Badge tone="red">{t('common.inactive')}</Badge>}</>} subtitle={<span className="font-mono">{data.code}{data.name_ar && <span className="ms-3 font-sans" dir="rtl">{data.name_ar}</span>}</span>}
        actions={w && <><Button variant="secondary" onClick={() => toggle.mutate()}>{data.is_active ? t('admin.deactivate') : t('admin.activate')}</Button><Button busy={save.isPending} onClick={() => save.mutate()}>{t('common.save')}</Button></>} />
      <div className="grid gap-4 xl:grid-cols-3">
        <Card title={t('common.details')} className="xl:col-span-2">
          <fieldset disabled={!w}><CustomerFields v={form} set={(k, v) => setForm((f) => ({ ...f, [k]: v }))} /></fieldset>
        </Card>
        <div className="space-y-4">
          <Card title={t('customer.contacts')} bodyClass="p-0" actions={w && <Button variant="secondary" onClick={() => setContactOpen(true)}><Plus className="h-4 w-4" />{t('common.add')}</Button>}>
            {data.contacts.length ? (
              <ul className="divide-y">
                {data.contacts.map((c: any) => (
                  <li key={c.id} className="flex items-start justify-between gap-2 px-4 py-2 text-sm">
                    <span><span className="font-medium">{c.full_name}</span> {c.is_primary && <Badge tone="blue">{t('customer.primary')}</Badge>}
                      <span className="block text-xs text-slate-500">{[c.position, c.email, c.phone].filter(Boolean).join(' · ')}</span></span>
                    {w && <span className="flex">
                      {!c.is_primary && <Button variant="ghost" aria-label={t('customer.primary')} onClick={() => primary.mutate(c.id)}><Star className="h-4 w-4" /></Button>}
                      <Button variant="ghost" aria-label={t('common.delete')} onClick={() => delContact.mutate(c.id)}><Trash2 className="h-4 w-4" /></Button>
                    </span>}
                  </li>
                ))}
              </ul>
            ) : <Empty />}
          </Card>
          <Card title={t('customer.opportunities')} bodyClass="p-0">
            {data.opportunities.length ? <ul className="divide-y">{data.opportunities.map((o: any) => (
              <li key={o.id} className="flex items-center justify-between px-4 py-2 text-sm"><Link className="link" to={`/opportunities/${o.id}`}>{o.number} — {o.title}</Link><Badge tone={STATUS_TONE[o.stage]}>{t(`stage.${o.stage}`)}</Badge></li>
            ))}</ul> : <Empty />}
          </Card>
          <Card title={t('customer.quotations')} bodyClass="p-0">
            {data.quotations.length ? <ul className="divide-y">{data.quotations.map((q: any) => (
              <li key={q.id} className="flex items-center justify-between px-4 py-2 text-sm"><Link className="link" to={`/quotations/${q.id}`}>{q.number} R{q.revision_no}</Link><span className="tabular-nums">{money(q.total_amount, q.currency)}</span></li>
            ))}</ul> : <Empty />}
          </Card>
          <Attachments entityType="customer" entityId={id!} canWrite={w} />
        </div>
      </div>
      <Modal open={contactOpen} onClose={() => setContactOpen(false)} title={t('customer.newContact')}
        footer={<><Button variant="secondary" onClick={() => setContactOpen(false)}>{t('common.cancel')}</Button><Button busy={addContact.isPending} onClick={() => addContact.mutate()}>{t('common.add')}</Button></>}>
        <ErrorBox error={addContact.error} />
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('common.name')}><Input value={contact.full_name} onChange={(e) => setContact({ ...contact, full_name: e.target.value })} name="contact_name" /></Field>
          <Field label={t('customer.position')}><Input value={contact.position} onChange={(e) => setContact({ ...contact, position: e.target.value })} /></Field>
          <Field label={t('common.email')}><Input type="email" value={contact.email} onChange={(e) => setContact({ ...contact, email: e.target.value })} /></Field>
          <Field label={t('common.phone')}><Input value={contact.phone} onChange={(e) => setContact({ ...contact, phone: e.target.value })} /></Field>
          <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={contact.is_primary} onChange={(e) => setContact({ ...contact, is_primary: e.target.checked })} />{t('customer.primary')}</label>
        </div>
      </Modal>
    </div>
  );
}
