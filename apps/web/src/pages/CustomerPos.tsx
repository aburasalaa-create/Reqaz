// Purchase orders received from customers: register, compare with the quotation, accept, turn into the project, bill.
import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Plus, Trash2 } from 'lucide-react';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { date, money, num, pick } from '../lib/format';
import { Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Select, Spinner, Textarea, cx, useToast } from '../components/ui';
import { Approvals, Row, Status, today, useLookups, useReason } from '../components/fin';
import Attachments from '../components/Attachments';

const STATUSES = ['received', 'under_review', 'clarification_required', 'accepted', 'rejected', 'active', 'completed', 'closed', 'cancelled'];

export function CustomerPos() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('');
  const [open, setOpen] = useState(false);
  const { data, isLoading, error } = useQuery({ queryKey: ['customer-pos', q, status], queryFn: () => api.get(`/customer-pos${qs({ q, status })}`) });
  return (
    <div>
      <PageHeader title={t('fin.customerPos')} subtitle={t('fin.customerPosHint')} actions={<>
        <Input className="w-56" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
        <Select className="w-48" value={status} onChange={(e) => setStatus(e.target.value)}>
          <option value="">{t('common.all')}</option>{STATUSES.map((s) => <option key={s} value={s}>{t(`fin.status.${s}`)}</option>)}
        </Select>
        {can('customer_pos.write') && <Button onClick={() => setOpen(true)} data-testid="new-cpo"><Plus className="h-4 w-4" />{t('fin.registerPo')}</Button>}
      </>} />
      <Card bodyClass="p-0">
        {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : !data?.length ? <Empty /> : (
          <div className="overflow-x-auto"><table className="w-full text-sm"><thead className="bg-slate-50"><tr>
            <th className="th">{t('common.number')}</th><th className="th">{t('fin.customerPoNo')}</th><th className="th">{t('common.customer')}</th>
            <th className="th">{t('common.status')}</th><th className="th">{t('common.date')}</th><th className="th">{t('fin.project')}</th>
            <th className="th text-end">{t('fin.amountExVat')}</th><th className="th text-end">{t('fin.billed')}</th>
          </tr></thead><tbody className="divide-y">
            {data.map((o: any) => (
              <tr key={o.id}>
                <td className="td font-mono text-xs"><Link className="link" to={`/customer-pos/${o.id}`}>{o.number}</Link></td>
                <td className="td">{o.customer_po_number}{o.po_type !== 'original' && <span className="text-xs text-slate-400"> · {t(`fin.poType.${o.po_type}`)}</span>}</td>
                <td className="td">{pick(o.customer_name, o.customer_name_ar)}</td><td className="td"><Status value={o.status} /></td>
                <td className="td">{date(o.po_date)}</td><td className="td">{o.project_number}</td>
                <td className="td num">{money(o.amount, o.currency)}</td><td className="td num">{money(o.billed)}</td>
              </tr>
            ))}
          </tbody></table></div>
        )}
      </Card>
      <RegisterPo open={open} onClose={() => setOpen(false)} />
    </div>
  );
}

function RegisterPo({ open, onClose, parent }: { open: boolean; onClose: () => void; parent?: any }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const blank = { customer_po_number: '', po_date: today(), quotation_id: '', customer_id: '', po_type: parent ? 'amendment' : 'original', amount: '', payment_terms: '', completion_date: '', copy: true };
  const [f, setF] = useState<any>(blank);
  const quotes = useQuery({ queryKey: ['quotations', 'for-po'], queryFn: () => api.get('/quotations?status=open&limit=200'), enabled: open && !parent });
  const customers = useQuery({ queryKey: ['customers', 'select'], queryFn: () => api.get('/customers?limit=500'), enabled: open && !parent });
  const create = useMutation({
    mutationFn: () => api.post('/customer-pos', {
      customer_po_number: f.customer_po_number, po_date: f.po_date, po_type: f.po_type,
      quotation_id: parent ? parent.quotation_id ?? undefined : f.quotation_id || undefined,
      customer_id: parent ? undefined : f.quotation_id ? undefined : f.customer_id || undefined,
      parent_id: parent?.id, project_id: parent?.project_id ?? undefined,
      amount: f.copy && f.quotation_id ? undefined : f.amount || undefined,
      payment_terms: f.payment_terms || undefined, completion_date: f.completion_date || undefined,
      copy_quotation_lines: !parent && !!f.quotation_id && f.copy,
    }),
    onSuccess: (po) => { onClose(); setF(blank); nav(`/customer-pos/${po.id}`); },
  });
  const set = (k: string) => (e: any) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  return (
    <Modal open={open} onClose={onClose} title={parent ? t('fin.registerChange') : t('fin.registerPo')} wide
      footer={<><Button variant="secondary" onClick={onClose}>{t('common.cancel')}</Button><Button busy={create.isPending} onClick={() => create.mutate()} data-testid="save-cpo">{t('common.create')}</Button></>}>
      <ErrorBox error={create.error} />
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label={t('fin.customerPoNo')}><Input name="customer_po_number" value={f.customer_po_number} onChange={set('customer_po_number')} /></Field>
        <Field label={t('fin.poDate')}><Input name="po_date" type="date" value={f.po_date} onChange={set('po_date')} /></Field>
        {parent ? (
          <Field label={t('fin.changeType')}><Select name="po_type" value={f.po_type} onChange={set('po_type')}>
            {['amendment', 'supplementary', 'partial'].map((x) => <option key={x} value={x}>{t(`fin.poType.${x}`)}</option>)}</Select></Field>
        ) : <>
          <Field label={t('fin.againstQuotation')} hint={t('fin.againstQuotationHint')}>
            <Select name="quotation_id" value={f.quotation_id} onChange={set('quotation_id')}>
              <option value="">{t('fin.noQuotation')}</option>
              {quotes.data?.map((q: any) => <option key={q.id} value={q.id}>{q.number} · {pick(q.customer_name, q.customer_name_ar)} · {money(q.net_amount)}</option>)}
            </Select>
          </Field>
          {!f.quotation_id && <Field label={t('common.customer')}><Select name="customer_id" value={f.customer_id} onChange={set('customer_id')}>
            <option value="">{t('common.select')}</option>{customers.data?.map((c: any) => <option key={c.id} value={c.id}>{pick(c.name_en, c.name_ar)}</option>)}</Select></Field>}
          {f.quotation_id && <label className="flex items-center gap-2 self-end pb-2 text-sm"><input type="checkbox" name="copy" checked={f.copy} onChange={set('copy')} />{t('fin.copyLines')}</label>}
        </>}
        {(parent || !f.quotation_id || !f.copy) && <Field label={t('fin.amountExVat')} hint={t('fin.amountHint')}><Input name="amount" type="number" step="any" value={f.amount} onChange={set('amount')} /></Field>}
        <Field label={t('pur.paymentTerms')}><Input name="payment_terms" value={f.payment_terms} onChange={set('payment_terms')} /></Field>
        <Field label={t('fin.completionDate')}><Input name="completion_date" type="date" value={f.completion_date} onChange={set('completion_date')} /></Field>
      </div>
    </Modal>
  );
}

export function CustomerPoDetail() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const nav = useNavigate();
  const qc = useQueryClient();
  const reason = useReason();
  const lookups = useLookups();
  const { data: po, isLoading, error } = useQuery({ queryKey: ['customer-po', id], queryFn: () => api.get(`/customer-pos/${id}`) });
  const [convert, setConvert] = useState<any>(null);
  const [bill, setBill] = useState<'advance' | 'progress' | null>(null);
  const [change, setChange] = useState(false);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['customer-po', id] }); qc.invalidateQueries({ queryKey: ['customer-pos'] }); };
  const onError = (e: Error) => { toast(e.message, 'error'); refresh(); };
  const act = (a: string, note?: string) => api.post(`/customer-pos/${id}/${a}`, note ? { note } : {}).then(refresh, onError);
  const patch = (b: any) => api.patch(`/customer-pos/${id}`, b).then(refresh, onError);
  const doConvert = useMutation({ mutationFn: (b: any) => api.post(`/customer-pos/${id}/convert`, b), onSuccess: () => { setConvert(null); refresh(); toast(t('fin.converted')); }, onError });

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const open = ['received', 'under_review', 'clarification_required'].includes(po.status);
  const editable = open && can('customer_pos.write');
  const billable = ['active', 'accepted'].includes(po.status) && po.project_id && can('invoices.write');
  const field = (k: string, type = 'text') => (
    <Input type={type} name={k} disabled={!editable} defaultValue={po[k] ?? ''} key={`${k}-${po.updated_at}`}
      onBlur={(e) => { if ((e.target.value || null) !== (po[k] ?? null)) patch({ [k]: e.target.value || null }); }} />
  );
  const cmp = po.comparison;
  const claimed = (lineId: string) => Number(po.progress?.find((p: any) => p.po_line_id === lineId)?.claimed_pct ?? 0);

  return (
    <div className="space-y-4">
      <PageHeader
        title={<span className="flex flex-wrap items-center gap-2">{t('fin.customerPo')} <span className="font-mono">{po.number}</span><Status value={po.status} /></span>}
        subtitle={<>{pick(po.customer_name, po.customer_name_ar)} · {t('fin.theirRef')} <b>{po.customer_po_number}</b>
          {po.po_type !== 'original' && <> · {t(`fin.poType.${po.po_type}`)} {po.parent_number && <Link className="link" to={`/customer-pos/${po.parent_id}`}>{po.parent_number}</Link>}</>}
          {po.quotation_number && <> · <Link className="link" to={`/quotations/${po.quotation_id}`}>{po.quotation_number}</Link> R{po.revision_no}</>}
          {po.project_number && <> · <Link className="link" to={`/projects/${po.project_id}`}>{po.project_number}</Link></>}</>}
        actions={<>
          {po.status === 'received' && can('customer_pos.write') && <Button variant="secondary" onClick={() => act('review')} data-testid="cpo-review">{t('fin.startReview')}</Button>}
          {po.status === 'under_review' && can('customer_pos.write') && <Button variant="secondary" onClick={() => reason.ask(t('fin.askClarification'), (n) => act('clarify', n))}>{t('fin.askClarification')}</Button>}
          {po.status === 'clarification_required' && can('customer_pos.write') && <Button variant="secondary" onClick={() => act('resume')}>{t('fin.resumeReview')}</Button>}
          {open && can('customer_pos.accept') && <>
            <Button variant="danger" onClick={() => reason.ask(t('quote.reject'), (n) => act('reject', n), { danger: true })}>{t('quote.reject')}</Button>
            <Button variant="success" data-testid="cpo-accept" onClick={() => reason.ask(t('fin.acceptPo'), (n) => act('accept', n || undefined), { required: false })}>{t('fin.acceptPo')}</Button>
          </>}
          {po.status === 'accepted' && can('customer_pos.accept') && <Button data-testid="cpo-convert" onClick={() => setConvert({ project_name: '', project_manager_id: '', start_date: today(), target_completion_date: po.completion_date ?? '', retention_pct: '', advance_payment_pct: '' })}>{po.project_id ? t('fin.addToProject') : t('fin.createProject')}</Button>}
          {billable && <><Button variant="secondary" onClick={() => setBill('advance')} data-testid="bill-advance">{t('fin.billAdvance')}</Button>
            <Button onClick={() => setBill('progress')} data-testid="bill-progress">{t('fin.billProgress')}</Button></>}
          {['active', 'accepted'].includes(po.status) && can('customer_pos.write') && <Button variant="secondary" onClick={() => setChange(true)}>{t('fin.registerChange')}</Button>}
          {po.status === 'active' && can('customer_pos.write') && <Button variant="ghost" onClick={() => act('complete')}>{t('fin.markComplete')}</Button>}
          {po.status === 'completed' && can('customer_pos.write') && <Button variant="ghost" onClick={() => act('close')}>{t('pur.close')}</Button>}
          {open && can('customer_pos.write') && <Button variant="ghost" onClick={() => reason.ask(t('common.cancel'), (n) => act('cancel', n), { danger: true })}>{t('common.cancel')}</Button>}
        </>} />
      {po.status_note && <div className="rounded-md border bg-slate-50 p-3 text-sm">“{po.status_note}”</div>}

      <div className="grid gap-4 lg:grid-cols-3">
        <Card title={t('fin.orderLines')} bodyClass="p-0" className="lg:col-span-2">
          <PoLines po={po} editable={editable} refresh={refresh} onError={onError} />
        </Card>
        <div className="space-y-4">
          <Card title={t('fin.value')}>
            <dl className="space-y-1.5 text-sm">
              <Row label={t('fin.amountExVat')} testId="cpo-amount">{money(po.amount)}</Row>
              <Row label={`${t('inv.vat')} ${num(po.vat_rate, 2)}%`}>{money(po.vat_amount)}</Row>
              <Row label={t('common.total')} strong>{money(po.total_amount, po.currency)}</Row>
              <Row label={t('fin.billed')}>{money(po.billing.billed)}</Row>
              <Row label={t('fin.leftToBill')}>{money(po.billing.remaining)}</Row>
              <Row label={t('fin.receivedFromCustomer')}>{money(po.billing.received)}</Row>
              <Row label={t('fin.outstanding')}>{money(po.billing.outstanding)}</Row>
              <Row label={t('fin.retentionHeld')}>{money(po.billing.retention_held)}</Row>
            </dl>
          </Card>
          <Approvals info={po.approvals} />
        </div>
      </div>

      {cmp && (
        <Card title={<>{t('fin.comparison')} · {cmp.quotation.number} R{cmp.quotation.revision_no} {cmp.differences > 0
          ? <span className="ms-2 text-xs font-normal text-amber-700" data-testid="cpo-differences">{t('fin.differences', { count: cmp.differences })}</span>
          : <span className="ms-2 text-xs font-normal text-emerald-700">{t('fin.noDifferences')}</span>}</>} bodyClass="p-0">
          <div className="grid gap-0 lg:grid-cols-3">
            <dl className="space-y-1 border-b p-4 text-sm lg:border-b-0 lg:border-e">
              {cmp.summary.map((s: any) => (
                <div key={s.field} className="flex justify-between gap-2">
                  <dt className="text-slate-500">{t(`fin.cmp.${s.field}`)}</dt>
                  <dd className={cx('text-end', s.match === false && 'font-medium text-amber-700')}>
                    <span className="text-slate-400">{fmt(s.quoted)}</span> → {fmt(s.ordered)}
                  </dd>
                </div>
              ))}
            </dl>
            <div className="overflow-x-auto lg:col-span-2"><table className="w-full text-sm"><thead className="bg-slate-50"><tr>
              <th className="th">{t('pur.item')}</th><th className="th text-end">{t('fin.quotedQty')}</th><th className="th text-end">{t('fin.orderedQty')}</th>
              <th className="th text-end">{t('fin.quotedRate')}</th><th className="th text-end">{t('fin.orderedRate')}</th><th className="th text-end">{t('fin.difference')}</th>
            </tr></thead><tbody className="divide-y">
              {cmp.lines.map((l: any, i: number) => (
                <tr key={i} className={l.issues.length ? 'bg-amber-50/60' : ''}>
                  <td className="td">{l.description}{l.issues.length > 0 && <div className="text-xs text-amber-700">{l.issues.map((x: string) => t(`fin.issue.${x}`)).join(', ')}</div>}</td>
                  <td className="td num">{num(l.quoted_qty)} {l.quoted_unit}</td><td className="td num">{num(l.po_qty)} {l.po_unit}</td>
                  <td className="td num">{money(l.quoted_rate)}</td><td className="td num">{money(l.po_rate)}</td>
                  <td className={cx('td num', Number(l.difference) < 0 && 'text-red-700')}>{money(l.difference)}</td>
                </tr>
              ))}
            </tbody></table></div>
          </div>
        </Card>
      )}

      <div className="grid gap-4 lg:grid-cols-2">
        <Card title={t('inv.details')}>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label={t('fin.customerPoNo')}>{field('customer_po_number')}</Field>
            <Field label={t('fin.poDate')}>{field('po_date', 'date')}</Field>
            <Field label={t('fin.receivedDate')}>{field('received_date', 'date')}</Field>
            <Field label={t('fin.amountExVat')}>{field('amount', 'number')}</Field>
            <Field label={t('pur.paymentTerms')}>{field('payment_terms')}</Field>
            <Field label={t('pur.deliveryDate')}>{field('delivery_date', 'date')}</Field>
            <Field label={t('fin.completionDate')}>{field('completion_date', 'date')}</Field>
            <Field label={t('fin.responsible')}>
              <Select name="responsible_user_id" disabled={!editable} value={po.responsible_user_id ?? ''} onChange={(e) => patch({ responsible_user_id: e.target.value || null })}>
                <option value="">—</option>{lookups.data?.users.map((u: any) => <option key={u.id} value={u.id}>{pick(u.full_name, u.full_name_ar)}</option>)}
              </Select>
            </Field>
            <Field label={t('fin.scopeNotes')} className="sm:col-span-2"><Textarea name="scope_notes" disabled={!editable} defaultValue={po.scope_notes ?? ''} key={`scope-${po.updated_at}`}
              onBlur={(e) => e.target.value !== (po.scope_notes ?? '') && patch({ scope_notes: e.target.value })} /></Field>
          </div>
          {po.accepted_by_name && <p className="mt-3 text-xs text-slate-500">{t('fin.acceptedBy')} {po.accepted_by_name}</p>}
        </Card>
        <div className="space-y-4">
          <Milestones po={po} refresh={refresh} onError={onError} canBill={!!billable} />
          <Card title={t('fin.invoices')} bodyClass="p-0">
            {!po.invoices.length ? <Empty /> : (
              <table className="w-full text-sm"><tbody className="divide-y">
                {po.invoices.map((i: any) => (
                  <tr key={i.id}>
                    <td className="td font-mono text-xs"><Link className="link" to={`/invoices/${i.id}`}>{i.number ?? t('pur.draft')}</Link></td>
                    <td className="td">{t(`fin.billing.${i.billing_type ?? 'standard'}`)}{i.claim_no && ` #${i.claim_no}`}</td>
                    <td className="td"><Status value={i.status} /></td><td className="td num">{money(i.total_amount)}</td>
                  </tr>
                ))}
              </tbody></table>
            )}
          </Card>
          {po.related?.length > 0 && <Card title={t('fin.relatedOrders')} bodyClass="p-0">
            <table className="w-full text-sm"><tbody className="divide-y">{po.related.map((r: any) => (
              <tr key={r.id}><td className="td font-mono text-xs"><Link className="link" to={`/customer-pos/${r.id}`}>{r.number}</Link></td>
                <td className="td">{r.customer_po_number} · {t(`fin.poType.${r.po_type}`)}</td><td className="td"><Status value={r.status} /></td><td className="td num">{money(r.amount)}</td></tr>
            ))}</tbody></table>
          </Card>}
        </div>
      </div>
      <Attachments entityType="customer_po" entityId={po.id} canWrite={can('customer_pos.write')} />

      <Modal open={!!convert} onClose={() => setConvert(null)} title={po.project_id ? t('fin.addToProject') : t('fin.createProject')}
        footer={<Button busy={doConvert.isPending} data-testid="convert-confirm" onClick={() => doConvert.mutate(Object.fromEntries(Object.entries(convert).filter(([, v]) => v !== '')))}>{t('common.confirm')}</Button>}>
        {convert && !po.project_id && <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('fin.projectName')} className="sm:col-span-2"><Input name="project_name" placeholder={po.customer_name} value={convert.project_name} onChange={(e) => setConvert({ ...convert, project_name: e.target.value })} /></Field>
          <Field label={t('project.pm')}><Select name="project_manager_id" value={convert.project_manager_id} onChange={(e) => setConvert({ ...convert, project_manager_id: e.target.value })}>
            <option value="">—</option>{lookups.data?.users.map((u: any) => <option key={u.id} value={u.id}>{pick(u.full_name, u.full_name_ar)}</option>)}</Select></Field>
          <Field label={t('project.start')}><Input type="date" value={convert.start_date} onChange={(e) => setConvert({ ...convert, start_date: e.target.value })} /></Field>
          <Field label={t('project.target')}><Input type="date" value={convert.target_completion_date} onChange={(e) => setConvert({ ...convert, target_completion_date: e.target.value })} /></Field>
          <Field label={t('fin.retentionPct')}><Input name="retention_pct" type="number" step="any" value={convert.retention_pct} onChange={(e) => setConvert({ ...convert, retention_pct: e.target.value })} /></Field>
          <Field label={t('fin.advancePct')}><Input name="advance_payment_pct" type="number" step="any" value={convert.advance_payment_pct} onChange={(e) => setConvert({ ...convert, advance_payment_pct: e.target.value })} /></Field>
        </div>}
        {convert && po.project_id && <p className="text-sm">{t('fin.addToProjectHint', { project: po.project_number })}</p>}
        <ErrorBox error={doConvert.error} />
      </Modal>
      {bill && <BillModal po={po} type={bill} claimed={claimed} onClose={() => setBill(null)} onDone={(inv) => nav(`/invoices/${inv}`)} />}
      <RegisterPo open={change} onClose={() => setChange(false)} parent={po} />
      {reason.modal}
    </div>
  );
}

const fmt = (v: any) => (v === null || v === undefined || v === '' ? '—' : !isNaN(Number(v)) && String(v).includes('.') ? money(v) : String(v));

function PoLines({ po, editable, refresh, onError }: { po: any; editable: boolean; refresh: () => void; onError: (e: Error) => void }) {
  const { t } = useTranslation();
  const blank = { description: '', unit: 'LS', quantity: '1', unit_price: '' };
  const [row, setRow] = useState<any>(blank);
  const cell = 'w-full rounded border border-transparent bg-transparent px-1 py-0.5 hover:border-slate-300 focus:border-brand-500 focus:bg-white focus:outline-none';
  const edit = (l: any, k: string, cls = '') => editable
    ? <input className={cx(cell, cls)} defaultValue={l[k] ?? ''} key={`${l.id}-${k}-${l.updated_at}`} type={['description', 'unit'].includes(k) ? 'text' : 'number'} step="any"
        onBlur={(e) => { if (e.target.value !== String(l[k] ?? '')) api.patch(`/customer-po-lines/${l.id}`, { [k]: e.target.value }).then(refresh, onError); }} />
    : <span className={cx('block px-1', cls)}>{k === 'quantity' ? num(l[k]) : k === 'unit_price' ? money(l[k]) : l[k]}</span>;
  const add = () => row.description.trim() && api.post(`/customer-pos/${po.id}/lines`, row).then(() => { setRow(blank); refresh(); }, onError);
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[560px] text-sm"><thead className="bg-slate-50"><tr>
        <th className="th">{t('pur.item')}</th><th className="th w-16">{t('quote.unit')}</th><th className="th w-24 text-end">{t('quote.qty')}</th>
        <th className="th w-32 text-end">{t('pur.unitPrice')}</th><th className="th w-32 text-end">{t('fin.amountExVat')}</th>{editable && <th className="w-8" />}
      </tr></thead><tbody className="divide-y">
        {po.lines.map((l: any) => (
          <tr key={l.id}>
            <td className="px-2 py-1">{edit(l, 'description')}</td><td className="px-2 py-1">{edit(l, 'unit')}</td>
            <td className="px-2 py-1">{edit(l, 'quantity', 'text-end tabular-nums')}</td><td className="px-2 py-1">{edit(l, 'unit_price', 'text-end tabular-nums')}</td>
            <td className="px-2 py-1 text-end font-medium tabular-nums">{money(l.amount)}</td>
            {editable && <td className="px-1"><button aria-label={t('common.delete')} className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600"
              onClick={() => api.del(`/customer-po-lines/${l.id}`).then(refresh, onError)}><Trash2 className="h-4 w-4" /></button></td>}
          </tr>
        ))}
        {editable && (
          <tr className="bg-slate-50/60">
            <td className="px-2 py-1"><Input name="new_description" placeholder={t('pur.addItem')} value={row.description} onChange={(e) => setRow({ ...row, description: e.target.value })} /></td>
            <td className="px-2 py-1"><Input value={row.unit} onChange={(e) => setRow({ ...row, unit: e.target.value })} /></td>
            <td className="px-2 py-1"><Input type="number" step="any" className="text-end" value={row.quantity} onChange={(e) => setRow({ ...row, quantity: e.target.value })} /></td>
            <td className="px-2 py-1"><Input type="number" step="any" className="text-end" value={row.unit_price} onChange={(e) => setRow({ ...row, unit_price: e.target.value })} /></td>
            <td className="px-2 py-1 text-end" colSpan={2}><Button variant="secondary" onClick={add}><Plus className="h-4 w-4" />{t('common.add')}</Button></td>
          </tr>
        )}
      </tbody></table>
      {!po.lines.length && !editable && <Empty>{t('fin.wholeOrder')}</Empty>}
      {editable && po.quotation_revision_id && !po.lines.length && <div className="p-3"><Button variant="secondary" onClick={() => api.post(`/customer-pos/${po.id}/copy-quotation`).then(refresh, onError)}>{t('fin.copyLines')}</Button></div>}
    </div>
  );
}

function Milestones({ po, refresh, onError, canBill }: { po: any; refresh: () => void; onError: (e: Error) => void; canBill: boolean }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const { can } = useAuth();
  const [m, setM] = useState({ label: '', percent: '', due_date: '' });
  const editable = can('customer_pos.write') && !['closed', 'cancelled', 'rejected'].includes(po.status);
  return (
    <Card title={t('fin.milestones')} bodyClass="p-0">
      {po.milestones.length > 0 && <table className="w-full text-sm"><tbody className="divide-y">
        {po.milestones.map((x: any) => (
          <tr key={x.id}>
            <td className="td">{x.label}<div className="text-xs text-slate-400">{date(x.due_date)}</div></td>
            <td className="td num">{x.percent ? `${num(x.percent, 2)}%` : money(x.amount)}</td>
            <td className="td text-end">
              {x.invoice ? <Link className="link text-xs" to={`/invoices/${x.invoice.id}`}>{x.invoice.number ?? t('pur.draft')}</Link>
                : canBill ? <Button variant="secondary" onClick={() => api.post(`/customer-pos/${po.id}/invoices`, { type: 'milestone', milestone_id: x.id }).then((r) => nav(`/invoices/${r.invoice_id}`), onError)}>{t('fin.bill')}</Button>
                : editable && <button className="rounded p-1 text-slate-400 hover:text-red-600" aria-label={t('common.delete')} onClick={() => api.del(`/customer-po-milestones/${x.id}`).then(refresh, onError)}><Trash2 className="h-4 w-4" /></button>}
            </td>
          </tr>
        ))}
      </tbody></table>}
      {editable && <div className="flex flex-wrap items-end gap-2 border-t p-3">
        <Input className="min-w-0 flex-1" placeholder={t('fin.milestoneLabel')} value={m.label} onChange={(e) => setM({ ...m, label: e.target.value })} />
        <Input className="w-20" type="number" step="any" placeholder="%" value={m.percent} onChange={(e) => setM({ ...m, percent: e.target.value })} />
        <Input className="w-36" type="date" value={m.due_date} onChange={(e) => setM({ ...m, due_date: e.target.value })} />
        <Button variant="secondary" onClick={() => m.label && api.post(`/customer-pos/${po.id}/milestones`, { label: m.label, percent: m.percent || null, due_date: m.due_date || null })
          .then(() => { setM({ label: '', percent: '', due_date: '' }); refresh(); }, onError)}><Plus className="h-4 w-4" />{t('common.add')}</Button>
      </div>}
      {!po.milestones.length && !editable && <Empty />}
    </Card>
  );
}

function BillModal({ po, type, claimed, onClose, onDone }: { po: any; type: 'advance' | 'progress'; claimed: (id: string) => number; onClose: () => void; onDone: (id: string) => void }) {
  const { t } = useTranslation();
  const [pct, setPct] = useState<Record<string, string>>({});
  const [adv, setAdv] = useState('');
  const run = useMutation({
    mutationFn: () => type === 'advance'
      ? api.post(`/customer-pos/${po.id}/invoices`, { type: 'advance', percent: adv })
      : api.post(`/customer-pos/${po.id}/invoices`, { type: 'progress', lines: po.lines.length
        ? po.lines.filter((l: any) => pct[l.id]).map((l: any) => ({ po_line_id: l.id, cumulative_pct: pct[l.id] }))
        : [{ po_line_id: null, cumulative_pct: pct.whole }] }),
    onSuccess: (r) => { onClose(); onDone(r.invoice_id); },
  });
  return (
    <Modal open onClose={onClose} wide title={type === 'advance' ? t('fin.billAdvance') : t('fin.billProgress')}
      footer={<Button busy={run.isPending} onClick={() => run.mutate()} data-testid="bill-confirm">{t('fin.createInvoice')}</Button>}>
      <ErrorBox error={run.error} />
      {type === 'advance' ? (
        <Field label={t('fin.advancePctOfOrder')} hint={t('fin.advanceHint')}><Input name="advance_pct" type="number" step="any" value={adv} onChange={(e) => setAdv(e.target.value)} /></Field>
      ) : (
        <>
          <p className="mb-2 text-sm text-slate-600">{t('fin.progressHint')}</p>
          <table className="w-full text-sm"><thead className="bg-slate-50"><tr>
            <th className="th">{t('pur.item')}</th><th className="th text-end">{t('fin.amountExVat')}</th><th className="th text-end">{t('fin.claimedSoFar')}</th><th className="th w-28 text-end">{t('fin.cumulativePct')}</th>
          </tr></thead><tbody className="divide-y">
            {(po.lines.length ? po.lines : [{ id: 'whole', description: t('fin.wholeOrder'), amount: po.amount }]).map((l: any) => (
              <tr key={l.id}>
                <td className="td">{l.description}</td><td className="td num">{money(l.amount)}</td>
                <td className="td num">{num(l.id === 'whole' ? po.whole_order_claimed_pct : claimed(l.id), 2)}%</td>
                <td className="td"><Input name={`pct_${l.id}`} type="number" step="any" className="text-end" value={pct[l.id] ?? ''} onChange={(e) => setPct({ ...pct, [l.id]: e.target.value })} /></td>
              </tr>
            ))}
          </tbody></table>
        </>
      )}
    </Modal>
  );
}
