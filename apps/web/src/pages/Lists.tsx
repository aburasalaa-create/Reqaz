// Simpler list pages: leads, tenders, quotations, suppliers, contracts & projects, audit.
import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Plus } from 'lucide-react';
import { LEAD_SOURCES, TENDER_STATUSES } from '@rms/shared';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { date, dateTime, daysUntil, money } from '../lib/format';
import Attachments from '../components/Attachments';
import NewQuotation from '../components/NewQuotation';
import { CustomerSelect } from '../components/OpportunityForm';
import { TenderFields, cleanTender } from '../components/TenderForm';
import { Badge, Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Select, Spinner, STATUS_TONE, Textarea, useToast } from '../components/ui';

function Table({ head, children }: { head: React.ReactNode[]; children: React.ReactNode }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full"><thead className="bg-slate-50"><tr>{head.map((h, i) => <th key={i} className="th">{h}</th>)}</tr></thead>
        <tbody className="divide-y">{children}</tbody></table>
    </div>
  );
}

export function Leads() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [status, setStatus] = useState('new');
  const [open, setOpen] = useState(false);
  const [conv, setConv] = useState<any>(null);
  const [form, setForm] = useState<any>({ source: 'phone', contact_name: '', company_name: '', email: '', phone: '', service_interest: '', message: '' });
  const { data, isLoading, error } = useQuery({ queryKey: ['leads', status], queryFn: () => api.get(`/leads${qs({ status })}`) });
  const create = useMutation({ mutationFn: () => api.post('/leads', form), onSuccess: () => { qc.invalidateQueries({ queryKey: ['leads'] }); setOpen(false); } });
  const convert = useMutation({ mutationFn: () => api.post(`/leads/${conv.id}/convert`, { customer_id: conv.customer_id || null }), onSuccess: (o) => nav(`/opportunities/${o.id}`), onError: (e: Error) => toast(e.message, 'error') });
  const reject = useMutation({ mutationFn: ({ id, spam }: { id: string; spam: boolean }) => api.post(`/leads/${id}/reject`, { spam }), onSuccess: () => qc.invalidateQueries({ queryKey: ['leads'] }) });
  const w = can('crm.write');
  return (
    <div>
      <PageHeader title={t('lead.title')} actions={<>
        <Select className="w-40" value={status} onChange={(e) => setStatus(e.target.value)}>{['new', 'converted', 'rejected', 'spam'].map((s) => <option key={s} value={s}>{s}</option>)}</Select>
        {w && <Button onClick={() => setOpen(true)}><Plus className="h-4 w-4" />{t('lead.new')}</Button>}</>} />
      <Card bodyClass="p-0">
        {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : !data.length ? <Empty /> : (
          <Table head={[t('lead.received'), t('opp.source'), t('lead.contact'), t('lead.service'), t('lead.message'), '']}>
            {data.map((l: any) => (
              <tr key={l.id} className="align-top">
                <td className="td whitespace-nowrap">{dateTime(l.received_at)}</td>
                <td className="td"><Badge tone={l.source === 'website' ? 'blue' : 'slate'}>{t(`source.${l.source}`)}</Badge></td>
                <td className="td">{l.contact_name}<div className="text-xs text-slate-500">{[l.company_name, l.email, l.phone].filter(Boolean).join(' · ')}</div></td>
                <td className="td">{l.service_interest}</td>
                <td className="td max-w-md text-slate-600">{l.message}</td>
                <td className="td whitespace-nowrap">
                  {l.status === 'new' && w ? <div className="flex gap-1">
                    <Button onClick={() => setConv({ id: l.id, customer_id: '' })}>{t('lead.convert')}</Button>
                    <Button variant="ghost" onClick={() => reject.mutate({ id: l.id, spam: false })}>{t('lead.reject')}</Button>
                    <Button variant="ghost" onClick={() => reject.mutate({ id: l.id, spam: true })}>{t('lead.spam')}</Button></div>
                    : l.opportunity_id ? <Link className="link" to={`/opportunities/${l.opportunity_id}`}>{t('common.view')}</Link> : <Badge tone={STATUS_TONE[l.status]}>{l.status}</Badge>}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </Card>
      <Modal open={open} onClose={() => setOpen(false)} title={t('lead.new')} footer={<><Button variant="secondary" onClick={() => setOpen(false)}>{t('common.cancel')}</Button><Button busy={create.isPending} onClick={() => create.mutate()}>{t('common.create')}</Button></>}>
        <ErrorBox error={create.error} />
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('opp.source')}><Select value={form.source} onChange={(e) => setForm({ ...form, source: e.target.value })}>{LEAD_SOURCES.map((s) => <option key={s} value={s}>{t(`source.${s}`)}</option>)}</Select></Field>
          {(['contact_name', 'company_name', 'email', 'phone', 'service_interest'] as const).map((k) => (
            <Field key={k} label={t(k === 'contact_name' ? 'lead.contact' : k === 'company_name' ? 'lead.company' : k === 'service_interest' ? 'lead.service' : `common.${k}`)}><Input value={form[k]} onChange={(e) => setForm({ ...form, [k]: e.target.value })} /></Field>
          ))}
          <Field label={t('lead.message')} className="sm:col-span-2"><Textarea value={form.message} onChange={(e) => setForm({ ...form, message: e.target.value })} /></Field>
        </div>
      </Modal>
      <Modal open={!!conv} onClose={() => setConv(null)} title={t('lead.convert')} footer={<><Button variant="secondary" onClick={() => setConv(null)}>{t('common.cancel')}</Button><Button busy={convert.isPending} onClick={() => convert.mutate()}>{t('common.confirm')}</Button></>}>
        <Field label={`${t('opp.linkCustomer')} (${t('common.optional')})`}><CustomerSelect value={conv?.customer_id ?? ''} onChange={(v) => setConv({ ...conv, customer_id: v })} /></Field>
      </Modal>
    </div>
  );
}

export function Tenders() {
  const { t } = useTranslation();
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('');
  const [upcoming, setUpcoming] = useState(false);
  const { data, isLoading, error } = useQuery({ queryKey: ['tenders', q, status, upcoming], queryFn: () => api.get(`/tenders${qs({ q, status, upcoming })}`) });
  return (
    <div>
      <PageHeader title={t('tender.title')} actions={<>
        <Input className="w-56" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
        <Select className="w-44" value={status} onChange={(e) => setStatus(e.target.value)}><option value="">{t('common.all')}</option>{TENDER_STATUSES.map((s) => <option key={s} value={s}>{t(`tenderStatus.${s}`)}</option>)}</Select>
        <label className="flex items-center gap-1 text-sm"><input type="checkbox" checked={upcoming} onChange={(e) => setUpcoming(e.target.checked)} />{t('tender.upcoming')}</label></>} />
      <Card bodyClass="p-0">
        {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : !data.length ? <Empty /> : (
          <Table head={[t('common.number'), t('common.title'), t('common.customer'), t('tender.clientRef'), t('tender.deadline'), t('common.status')]}>
            {data.map((x: any) => {
              const d = daysUntil(x.submission_deadline);
              const live = ['received', 'under_review', 'estimating'].includes(x.status);
              return (
                <tr key={x.id}>
                  <td className="td font-mono text-xs"><Link className="link" to={`/tenders/${x.id}`}>{x.number}</Link></td>
                  <td className="td">{x.title}</td><td className="td">{x.customer_name}</td><td className="td">{x.client_reference}</td>
                  <td className="td whitespace-nowrap">{dateTime(x.submission_deadline)} {live && <Badge tone={d <= 3 ? 'red' : d <= 7 ? 'amber' : 'slate'}>{d}d</Badge>}</td>
                  <td className="td"><Badge tone={STATUS_TONE[x.status]}>{t(`tenderStatus.${x.status}`)}</Badge></td>
                </tr>
              );
            })}
          </Table>
        )}
      </Card>
    </div>
  );
}

export function TenderDetail() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const { data, isLoading, error } = useQuery({ queryKey: ['tender', id], queryFn: () => api.get(`/tenders/${id}`) });
  const [form, setForm] = useState<any>(null);
  useEffect(() => { if (data) setForm(data); }, [data]);
  const save = useMutation({ mutationFn: () => api.patch(`/tenders/${id}`, cleanTender(form)), onSuccess: () => { qc.invalidateQueries({ queryKey: ['tender', id] }); toast(t('common.saved')); }, onError: (e: Error) => toast(e.message, 'error') });
  if (isLoading || !form) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const w = can('tenders.write');
  return (
    <div>
      <PageHeader title={<>{data.number} — {data.title} <Badge tone={STATUS_TONE[data.status]}>{t(`tenderStatus.${data.status}`)}</Badge></>}
        subtitle={<>{data.customer_name} · <Link className="link" to={`/opportunities/${data.opportunity_id}`}>{data.opportunity_number} {data.opportunity_title}</Link></>}
        actions={w && <Button busy={save.isPending} onClick={() => save.mutate()}>{t('common.save')}</Button>} />
      <div className="grid gap-4 xl:grid-cols-3">
        <Card title={t('common.details')} className="xl:col-span-2"><fieldset disabled={!w}><TenderFields v={form} set={(k, v) => setForm((f: any) => ({ ...f, [k]: v }))} showStatus /></fieldset></Card>
        <div className="space-y-4">
          <Card title={t('nav.quotations')} bodyClass="p-0">{data.quotations.length ? <ul className="divide-y">{data.quotations.map((q: any) => (
            <li key={q.id} className="flex justify-between px-4 py-2 text-sm"><Link className="link" to={`/quotations/${q.id}`}>{q.number}</Link><Badge tone={STATUS_TONE[q.status]}>{t(`quoteStatus.${q.status}`)}</Badge></li>))}</ul> : <Empty />}</Card>
          <Attachments entityType="tender" entityId={id!} canWrite={w} />
        </div>
      </div>
    </div>
  );
}

export function Quotations() {
  const { t } = useTranslation();
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('');
  const [rs, setRs] = useState('');
  const [creating, setCreating] = useState(false);
  const { can } = useAuth();
  const { data, isLoading, error } = useQuery({ queryKey: ['quotations', q, status, rs], queryFn: () => api.get(`/quotations${qs({ q, status, revision_status: rs })}`) });
  return (
    <div>
      <PageHeader title={t('quote.title')} subtitle={t('opp.linkCustomer') && undefined} actions={<>
        <Input className="w-56" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
        <Select className="w-36" value={status} onChange={(e) => setStatus(e.target.value)}><option value="">{t('common.all')}</option>{['open', 'won', 'lost', 'cancelled'].map((s) => <option key={s} value={s}>{t(`quoteStatus.${s}`)}</option>)}</Select>
        <Select className="w-44" value={rs} onChange={(e) => setRs(e.target.value)}><option value="">{t('common.all')}</option>{['draft', 'pending_approval', 'approved', 'submitted', 'awarded'].map((s) => <option key={s} value={s}>{t(`revStatus.${s}`)}</option>)}</Select>
        {can('quotations.write') && <Button onClick={() => setCreating(true)}><Plus className="h-4 w-4" />{t('quote.new')}</Button>}</>} />
      {creating && <NewQuotation open onClose={() => setCreating(false)} />}
      <Card bodyClass="p-0">
        {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : !data.length ? <Empty /> : (
          <Table head={[t('common.number'), t('common.title'), t('common.customer'), t('quote.revision'), t('common.status'), t('quote.validUntil'), t('quote.grossMargin'), t('quote.totalInclVat')]}>
            {data.map((x: any) => (
              <tr key={x.id}>
                <td className="td font-mono text-xs"><Link className="link" to={`/quotations/${x.id}`}>{x.number}</Link></td>
                <td className="td">{x.title}</td><td className="td">{x.customer_name}</td>
                <td className="td whitespace-nowrap">R{x.revision_no} <Badge tone={STATUS_TONE[x.revision_status]}>{t(`revStatus.${x.revision_status}`)}</Badge></td>
                <td className="td"><Badge tone={STATUS_TONE[x.status]}>{t(`quoteStatus.${x.status}`)}</Badge></td>
                <td className="td">{date(x.valid_until)}</td>
                <td className="td num">{x.gross_margin_pct !== null ? `${x.gross_margin_pct}%` : '—'}</td>
                <td className="td num">{money(x.total_amount, x.currency)}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>
    </div>
  );
}

export function Suppliers() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const qc = useQueryClient();
  const [q, setQ] = useState('');
  const [edit, setEdit] = useState<any>(null);
  const { data, isLoading, error } = useQuery({ queryKey: ['suppliers', q], queryFn: () => api.get(`/suppliers${qs({ q })}`) });
  const fields = ['name_en', 'name_ar', 'category', 'vat_number', 'cr_number', 'contact_name', 'email', 'phone', 'city', 'payment_terms_days', 'notes'];
  const save = useMutation({
    mutationFn: () => {
      const body = Object.fromEntries(fields.map((k) => [k, k === 'payment_terms_days' ? Number(edit[k] ?? 30) : edit[k] ?? '']));
      return edit.id ? api.patch(`/suppliers/${edit.id}`, body) : api.post('/suppliers', body);
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['suppliers'] }); setEdit(null); },
  });
  const label: Record<string, string> = { name_en: 'common.name', name_ar: 'common.nameAr', category: 'supplier.category', vat_number: 'customer.vat', cr_number: 'customer.cr',
    contact_name: 'supplier.contact', email: 'common.email', phone: 'common.phone', city: 'common.city', payment_terms_days: 'customer.terms', notes: 'common.notes' };
  return (
    <div>
      <PageHeader title={t('supplier.title')} actions={<><Input className="w-56" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
        {can('suppliers.write') && <Button onClick={() => setEdit({ payment_terms_days: 30 })}><Plus className="h-4 w-4" />{t('supplier.new')}</Button>}</>} />
      <Card bodyClass="p-0">
        {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : !data.length ? <Empty /> : (
          <Table head={[t('common.code'), t('common.name'), t('supplier.category'), t('customer.vat'), t('supplier.contact'), t('common.city')]}>
            {data.map((s: any) => (
              <tr key={s.id} className="cursor-pointer hover:bg-slate-50" onClick={() => can('suppliers.write') && setEdit(s)}>
                <td className="td font-mono text-xs">{s.code}</td><td className="td">{s.name_en}<div className="text-xs text-slate-500" dir="rtl">{s.name_ar}</div></td>
                <td className="td">{s.category}</td><td className="td font-mono text-xs">{s.vat_number}</td><td className="td">{s.contact_name}</td><td className="td">{s.city}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>
      <Modal open={!!edit} onClose={() => setEdit(null)} title={edit?.id ? edit.code : t('supplier.new')} wide
        footer={<><Button variant="secondary" onClick={() => setEdit(null)}>{t('common.cancel')}</Button><Button busy={save.isPending} onClick={() => save.mutate()}>{t('common.save')}</Button></>}>
        <ErrorBox error={save.error} />
        {edit && <div className="grid gap-3 sm:grid-cols-2">{fields.map((k) => (
          <Field key={k} label={t(label[k])} className={k === 'notes' ? 'sm:col-span-2' : ''}>
            {k === 'notes' ? <Textarea value={edit[k] ?? ''} onChange={(e) => setEdit({ ...edit, [k]: e.target.value })} />
              : <Input dir={k === 'name_ar' ? 'rtl' : undefined} type={k === 'payment_terms_days' ? 'number' : 'text'} value={edit[k] ?? ''} onChange={(e) => setEdit({ ...edit, [k]: e.target.value })} />}
          </Field>))}</div>}
      </Modal>
    </div>
  );
}

export function Projects() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const canContracts = can('contracts.read') || can('quotations.award');
  const contracts = useQuery({ queryKey: ['contracts'], queryFn: () => api.get('/contracts'), enabled: canContracts });
  const projects = useQuery({ queryKey: ['projects'], queryFn: () => api.get('/projects') });
  return (
    <div className="space-y-4">
      <PageHeader title={t('nav.projects')} subtitle={t('project.phase2')} />
      <Card title={t('project.projects')} bodyClass="p-0">
        {projects.isLoading ? <Spinner /> : !projects.data?.length ? <Empty /> : (
          <Table head={[t('common.number'), t('common.name'), t('common.customer'), t('project.pm'), t('project.start'), t('project.target'), t('project.budget'), t('common.status')]}>
            {projects.data.map((p: any) => (
              <tr key={p.id}><td className="td font-mono text-xs">{p.number}</td><td className="td">{p.name}</td><td className="td">{p.customer_name}</td><td className="td">{p.project_manager_name}</td>
                <td className="td">{date(p.start_date)}</td><td className="td">{date(p.target_completion_date)}</td><td className="td num">{money(p.approved_budget)}</td><td className="td"><Badge tone="blue">{p.status}</Badge></td></tr>
            ))}
          </Table>
        )}
      </Card>
      {canContracts && <Card title={t('project.contracts')} bodyClass="p-0">
        {contracts.isLoading ? <Spinner /> : !contracts.data?.length ? <Empty /> : (
          <Table head={[t('common.number'), t('common.title'), t('common.customer'), t('nav.quotations'), t('project.value'), t('common.date')]}>
            {contracts.data.map((c: any) => (
              <tr key={c.id}><td className="td font-mono text-xs">{c.number}</td><td className="td">{c.title}</td><td className="td">{c.customer_name}</td><td className="td">{c.quotation_number}</td>
                <td className="td num">{money(c.original_value, c.currency)}</td><td className="td">{date(c.signed_date ?? c.created_at)}</td></tr>
            ))}
          </Table>
        )}
      </Card>}
    </div>
  );
}

export function Audit() {
  const { t } = useTranslation();
  const [table, setTable] = useState('');
  const { data, isLoading, error } = useQuery({ queryKey: ['audit', table], queryFn: () => api.get(`/audit${qs({ table, limit: 200 })}`) });
  const [open, setOpen] = useState<any>(null);
  return (
    <div>
      <PageHeader title={t('audit.title')} actions={<Input className="w-56" placeholder={t('audit.table')} value={table} onChange={(e) => setTable(e.target.value.trim())} />} />
      <Card bodyClass="p-0">
        {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : !data.length ? <Empty /> : (
          <Table head={[t('audit.when'), t('audit.actor'), t('audit.action'), t('audit.table'), t('audit.record'), '']}>
            {data.map((a: any) => (
              <tr key={a.id}><td className="td whitespace-nowrap">{dateTime(a.occurred_at)}</td><td className="td">{a.actor_name ?? 'system'}</td>
                <td className="td"><Badge tone={a.action === 'DELETE' ? 'red' : a.action === 'INSERT' ? 'green' : a.action === 'EVENT' ? 'violet' : 'blue'}>{a.action}</Badge> {a.note}</td>
                <td className="td font-mono text-xs">{a.table_name}</td><td className="td font-mono text-xs">{a.record_id?.slice(0, 8)}</td>
                <td className="td"><button className="link text-xs" onClick={() => setOpen(a)}>{t('audit.changes')}</button></td></tr>
            ))}
          </Table>
        )}
      </Card>
      <Modal open={!!open} onClose={() => setOpen(null)} title={t('audit.changes')} wide>
        {open && <AuditDiff before={open.old_data} after={open.new_data} />}
      </Modal>
    </div>
  );
}

function AuditDiff({ before, after }: { before: any; after: any }) {
  const keys = Array.from(new Set([...Object.keys(before ?? {}), ...Object.keys(after ?? {})]))
    .filter((k) => JSON.stringify(before?.[k]) !== JSON.stringify(after?.[k]) && k !== 'updated_at');
  return (
    <table className="w-full text-xs"><tbody className="divide-y">{keys.map((k) => (
      <tr key={k}><td className="py-1 pe-2 font-mono text-slate-500">{k}</td><td className="py-1 pe-2 text-red-700 line-through">{JSON.stringify(before?.[k] ?? null)}</td><td className="py-1 text-emerald-700">{JSON.stringify(after?.[k] ?? null)}</td></tr>
    ))}</tbody></table>
  );
}
