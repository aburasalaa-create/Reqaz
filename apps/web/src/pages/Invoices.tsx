// Customer invoices, credit/debit notes and proformas: list, draft editor, issue, PDF and payments received.
// Amounts shown here always come from the server; the browser never calculates what is invoiced.
import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { FileDown, Plus, Trash2 } from 'lucide-react';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { date, money, num, pick } from '../lib/format';
import { CustomerSelect } from '../components/OpportunityForm';
import { Badge, Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Select, Spinner, Textarea, useToast, type Tone } from '../components/ui';

const KINDS = ['invoice', 'credit_note', 'debit_note', 'proforma'] as const;
const STATUS_TONES: Record<string, Tone> = { draft: 'slate', issued: 'green', cancelled: 'red' };

const outstanding = (i: any) => Number(i.amount_payable) - Number(i.amount_paid) - Number(i.credited_amount ?? 0);

function KindLabel({ inv }: { inv: any }) {
  const { t } = useTranslation();
  return <>{inv.kind === 'invoice' ? t(`inv.type.${inv.zatca_type}`) : t(`inv.kind.${inv.kind}`)}</>;
}

export function Invoices() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const nav = useNavigate();
  const toast = useToast();
  const [filter, setFilter] = useState({ kind: '', status: '', q: '' });
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<any>({ kind: 'invoice', zatca_type: 'standard', customer_id: '', currency: 'SAR' });
  const { data, isLoading, error } = useQuery({ queryKey: ['invoices', filter], queryFn: () => api.get(`/invoices${qs(filter)}`) });
  const ar = useQuery({ queryKey: ['receivables'], queryFn: () => api.get('/receivables') });
  const create = useMutation({
    mutationFn: () => api.post('/invoices', form),
    onSuccess: (inv) => nav(`/invoices/${inv.id}`),
    onError: (e: Error) => toast(e.message, 'error'),
  });
  const totalOutstanding = (ar.data ?? []).reduce((s: number, r: any) => s + Number(r.outstanding), 0);
  const overdue = (ar.data ?? []).filter((r: any) => r.days_overdue > 0).reduce((s: number, r: any) => s + Number(r.outstanding), 0);

  return (
    <div className="space-y-4">
      <PageHeader title={t('inv.title')} subtitle={t('inv.subtitle')} actions={<>
        <Input className="w-48" placeholder={t('common.search')} value={filter.q} onChange={(e) => setFilter({ ...filter, q: e.target.value })} />
        <Select className="w-40" value={filter.kind} onChange={(e) => setFilter({ ...filter, kind: e.target.value })}>
          <option value="">{t('common.all')}</option>{KINDS.map((k) => <option key={k} value={k}>{t(`inv.kind.${k}`)}</option>)}</Select>
        <Select className="w-32" value={filter.status} onChange={(e) => setFilter({ ...filter, status: e.target.value })}>
          <option value="">{t('common.all')}</option>{['draft', 'issued', 'cancelled'].map((s) => <option key={s} value={s}>{t(`inv.status.${s}`)}</option>)}</Select>
        {can('invoices.write') && <Button onClick={() => setOpen(true)} data-testid="new-invoice"><Plus className="h-4 w-4" />{t('inv.new')}</Button>}
      </>} />
      <div className="grid gap-3 sm:grid-cols-3">
        <Card><div className="text-xs text-slate-500">{t('inv.outstanding')}</div><div className="text-xl font-semibold">{money(totalOutstanding, 'SAR')}</div></Card>
        <Card><div className="text-xs text-slate-500">{t('inv.overdue')}</div><div className="text-xl font-semibold text-red-700">{money(overdue, 'SAR')}</div></Card>
        <Card><div className="text-xs text-slate-500">{t('inv.openCount')}</div><div className="text-xl font-semibold">{ar.data?.length ?? '—'}</div></Card>
      </div>
      <Card bodyClass="p-0">
        {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : !data.length ? <Empty /> : (
          <div className="overflow-x-auto"><table className="w-full">
            <thead className="bg-slate-50"><tr>{[t('common.number'), t('common.type'), t('common.customer'), t('inv.issueDate'), t('inv.dueDate'),
              t('inv.total'), t('inv.balance'), t('common.status')].map((h) => <th key={h} className="th">{h}</th>)}</tr></thead>
            <tbody className="divide-y">{data.map((i: any) => (
              <tr key={i.id} className="cursor-pointer hover:bg-slate-50" onClick={() => nav(`/invoices/${i.id}`)}>
                <td className="td font-mono text-xs">{i.number ?? <span className="text-slate-400">{t('inv.status.draft')}</span>}</td>
                <td className="td"><KindLabel inv={i} />{i.original_number && <div className="text-xs text-slate-500">→ {i.original_number}</div>}</td>
                <td className="td">{pick(i.customer_name, i.customer_name_ar)}<div className="text-xs text-slate-500">{i.title}</div></td>
                <td className="td">{date(i.issue_date)}</td>
                <td className="td">{date(i.due_date)}</td>
                <td className="td num">{money(i.total_amount, i.currency)}</td>
                <td className="td num">{i.status === 'issued' && ['invoice', 'debit_note'].includes(i.kind) ? money(outstanding(i)) : '—'}</td>
                <td className="td"><Badge tone={STATUS_TONES[i.status]}>{t(`inv.status.${i.status}`)}</Badge></td>
              </tr>))}</tbody>
          </table></div>
        )}
      </Card>
      <Modal open={open} onClose={() => setOpen(false)} title={t('inv.new')} footer={<Button busy={create.isPending} disabled={!form.customer_id} onClick={() => create.mutate()}>{t('common.create')}</Button>}>
        <div className="grid gap-3">
          <Field label={t('common.type')}><Select value={form.kind} onChange={(e) => setForm({ ...form, kind: e.target.value })}>
            <option value="invoice">{t('inv.kind.invoice')}</option><option value="proforma">{t('inv.kind.proforma')}</option></Select></Field>
          {form.kind === 'invoice' && <Field label={t('inv.zatcaType')}><Select value={form.zatca_type} onChange={(e) => setForm({ ...form, zatca_type: e.target.value })}>
            <option value="standard">{t('inv.type.standard')}</option><option value="simplified">{t('inv.type.simplified')}</option></Select></Field>}
          <Field label={t('common.customer')}><CustomerSelect value={form.customer_id} onChange={(v) => setForm({ ...form, customer_id: v })} /></Field>
          <Field label={t('inv.currency')}><Select value={form.currency} onChange={(e) => setForm({ ...form, currency: e.target.value })}>
            {['SAR', 'USD', 'EUR', 'AED'].map((c) => <option key={c}>{c}</option>)}</Select></Field>
          <p className="text-xs text-slate-500">{t('inv.creditHint')}</p>
        </div>
      </Modal>
    </div>
  );
}

const emptyLine = { description_en: '', description_ar: '', unit: 'LS', quantity: '1', unit_price: '0', discount_amount: '0', vat_code: 'S15', vat_exemption_reason: '' };

export function InvoiceDetail() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { data: inv, isLoading, error } = useQuery({ queryKey: ['invoice', id], queryFn: () => api.get(`/invoices/${id}`) });
  const vat = useQuery({ queryKey: ['lookups'], queryFn: () => api.get('/lookups') });
  const [line, setLine] = useState<any>(null);
  const [pay, setPay] = useState<any>(null);
  const [cancel, setCancel] = useState<string | null>(null);
  const [confirmIssue, setConfirmIssue] = useState(false);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['invoice', id] }); qc.invalidateQueries({ queryKey: ['invoices'] }); qc.invalidateQueries({ queryKey: ['receivables'] }); };
  const onError = (e: Error) => toast(e.message, 'error');

  const patch = useMutation({ mutationFn: (body: any) => api.patch(`/invoices/${id}`, body), onSuccess: refresh, onError });
  const saveLine = useMutation({
    mutationFn: (l: any) => {
      const { id: lineId, ...body } = l;
      for (const k of ['description_ar', 'vat_exemption_reason']) if (body[k] === '') body[k] = null;
      for (const k of ['gross_amount', 'net_amount', 'vat_amount', 'vat_rate', 'vat_category', 'invoice_id', 'created_at', 'updated_at', 'sort_order']) delete body[k];
      return lineId ? api.patch(`/invoice-lines/${lineId}`, body) : api.post(`/invoices/${id}/lines`, body);
    },
    onSuccess: () => { setLine(null); refresh(); }, onError,
  });
  const delLine = useMutation({ mutationFn: (lineId: string) => api.del(`/invoice-lines/${lineId}`), onSuccess: refresh, onError });
  const issue = useMutation({ mutationFn: () => api.post(`/invoices/${id}/issue`), onSuccess: () => { setConfirmIssue(false); refresh(); toast(t('inv.issued')); }, onError });
  const doCancel = useMutation({ mutationFn: () => api.post(`/invoices/${id}/cancel`, { reason: cancel }), onSuccess: () => { setCancel(null); refresh(); }, onError });
  const addPay = useMutation({ mutationFn: () => api.post(`/invoices/${id}/payments`, pay), onSuccess: () => { setPay(null); refresh(); }, onError });
  const voidPay = useMutation({ mutationFn: ({ pid, reason }: { pid: string; reason: string }) => api.post(`/payments/${pid}/void`, { reason }), onSuccess: refresh, onError });
  const note = useMutation({
    mutationFn: (kind: string) => api.post('/invoices', { kind, original_invoice_id: id, note_reason: '' }),
    onSuccess: (n) => nav(`/invoices/${n.id}`), onError,
  });

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const draft = inv.status === 'draft';
  const editable = draft && can('invoices.write');
  const credited = inv.notes.filter((n: any) => n.kind === 'credit_note' && n.status === 'issued').reduce((s: number, n: any) => s + Number(n.total_amount), 0);
  const balance = Number(inv.amount_payable) - Number(inv.amount_paid) - credited;
  const pdf = (lang: string) => api.openFile(`/invoices/${id}/pdf?lang=${lang}`).catch(onError);
  const field = (k: string, type = 'text') => (
    <Input type={type} disabled={!editable} defaultValue={inv[k] ?? ''} key={`${k}-${inv.updated_at}`}
      onBlur={(e) => { if ((e.target.value || null) !== (inv[k] ?? null)) patch.mutate({ [k]: e.target.value }); }} />
  );

  return (
    <div className="space-y-4">
      <PageHeader
        title={<span className="flex items-center gap-2"><KindLabel inv={inv} /> {inv.number && <span className="font-mono">{inv.number}</span>}
          <Badge tone={STATUS_TONES[inv.status]}>{t(`inv.status.${inv.status}`)}</Badge></span>}
        subtitle={<>{pick(inv.customer_name, inv.customer_name_ar)}{inv.original_number && <> · {t('inv.against')} <Link className="link" to={`/invoices/${inv.original_invoice_id}`}>{inv.original_number}</Link></>}</>}
        actions={<>
          <div className="inline-flex overflow-hidden rounded-md border">
            <button className="inline-flex items-center gap-1 bg-white px-2.5 py-1.5 text-sm hover:bg-slate-50" onClick={() => pdf('bilingual')}><FileDown className="h-4 w-4" />PDF</button>
            <button className="border-s bg-white px-2 py-1.5 text-sm hover:bg-slate-50" onClick={() => pdf('en')}>EN</button>
            <button className="border-s bg-white px-2 py-1.5 text-sm hover:bg-slate-50" onClick={() => pdf('ar')}>ع</button>
          </div>
          {draft && can('invoices.issue') && <Button onClick={() => setConfirmIssue(true)} data-testid="issue">{t('inv.issue')}</Button>}
          {inv.status === 'issued' && inv.kind === 'invoice' && can('invoices.write') && <>
            <Button variant="secondary" busy={note.isPending} onClick={() => note.mutate('credit_note')}>{t('inv.creditNote')}</Button>
            <Button variant="secondary" busy={note.isPending} onClick={() => note.mutate('debit_note')}>{t('inv.debitNote')}</Button></>}
          {((draft && can('invoices.write')) || (inv.status === 'issued' && inv.kind === 'proforma' && can('invoices.issue'))) &&
            <Button variant="ghost" onClick={() => setCancel('')}>{t('inv.cancel')}</Button>}
        </>} />

      {inv.status === 'issued' && inv.kind !== 'proforma' && <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">{t('inv.zatcaNote')}</div>}
      {inv.status === 'cancelled' && <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-900">{t('inv.cancelledBecause')}: {inv.cancel_reason}</div>}

      <div className="grid gap-4 lg:grid-cols-3">
        <Card title={t('inv.details')} className="lg:col-span-2">
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label={t('common.title')}>{field('title')}</Field>
            <Field label={t('inv.customerRef')}>{field('customer_reference')}</Field>
            <Field label={t('inv.supplyDate')}>{field('supply_date', 'date')}</Field>
            <Field label={t('inv.supplyEnd')}>{field('supply_end_date', 'date')}</Field>
            <Field label={t('inv.dueDate')} hint={draft ? t('inv.dueHint') : undefined}>{field('due_date', 'date')}</Field>
            {(inv.kind === 'credit_note' || inv.kind === 'debit_note') && <Field label={t('inv.reason')}>{field('note_reason')}</Field>}
            {inv.kind !== 'credit_note' && <>
              <Field label={t('inv.retentionPct')}>{field('retention_pct', 'number')}</Field>
              <Field label={t('inv.advance')}>{field('advance_deduction', 'number')}</Field></>}
            <Field label={t('inv.termsEn')} className="sm:col-span-2"><Textarea disabled={!editable} defaultValue={inv.payment_terms_en ?? ''} key={`te-${inv.updated_at}`}
              onBlur={(e) => e.target.value !== (inv.payment_terms_en ?? '') && patch.mutate({ payment_terms_en: e.target.value })} /></Field>
            <Field label={t('inv.termsAr')} className="sm:col-span-2"><Textarea dir="rtl" disabled={!editable} defaultValue={inv.payment_terms_ar ?? ''} key={`ta-${inv.updated_at}`}
              onBlur={(e) => e.target.value !== (inv.payment_terms_ar ?? '') && patch.mutate({ payment_terms_ar: e.target.value })} /></Field>
          </div>
        </Card>
        <Card title={t('inv.totals')}>
          <dl className="space-y-1.5 text-sm">
            {[['inv.subtotal', inv.subtotal], ['inv.discount', inv.discount_total], ['inv.taxable', inv.taxable_amount], ['inv.vat', inv.vat_total]].map(([k, v]) =>
              <div key={k} className="flex justify-between"><dt className="text-slate-500">{t(k)}</dt><dd className="num">{money(v)}</dd></div>)}
            <div className="flex justify-between border-t pt-1.5 font-semibold"><dt>{t('inv.total')}</dt><dd className="num" data-testid="total">{money(inv.total_amount, inv.currency)}</dd></div>
            {Number(inv.retention_amount) > 0 && <div className="flex justify-between"><dt className="text-slate-500">{t('inv.retention')}</dt><dd className="num">({money(inv.retention_amount)})</dd></div>}
            {Number(inv.advance_deduction) > 0 && <div className="flex justify-between"><dt className="text-slate-500">{t('inv.advance')}</dt><dd className="num">({money(inv.advance_deduction)})</dd></div>}
            {inv.kind !== 'credit_note' && <div className="flex justify-between font-semibold"><dt>{t('inv.payable')}</dt><dd className="num">{money(inv.amount_payable, inv.currency)}</dd></div>}
            {inv.status === 'issued' && ['invoice', 'debit_note'].includes(inv.kind) && <>
              <div className="flex justify-between"><dt className="text-slate-500">{t('inv.paid')}</dt><dd className="num">{money(inv.amount_paid)}</dd></div>
              {credited > 0 && <div className="flex justify-between"><dt className="text-slate-500">{t('inv.credited')}</dt><dd className="num">{money(credited)}</dd></div>}
              <div className="flex justify-between border-t pt-1.5 font-semibold"><dt>{t('inv.balance')}</dt><dd className="num">{money(balance, inv.currency)}</dd></div></>}
          </dl>
        </Card>
      </div>

      <Card title={t('inv.lines')} bodyClass="p-0" actions={editable && <Button onClick={() => setLine({ ...emptyLine })} data-testid="add-line"><Plus className="h-4 w-4" />{t('inv.addLine')}</Button>}>
        {!inv.lines.length ? <Empty /> : <div className="overflow-x-auto"><table className="w-full">
          <thead className="bg-slate-50"><tr>{['#', t('common.description'), t('inv.unit'), t('inv.qty'), t('inv.price'), t('inv.discount'), t('inv.taxable'), t('inv.vat'), t('inv.total'), ''].map((h, i) => <th key={i} className="th">{h}</th>)}</tr></thead>
          <tbody className="divide-y">{inv.lines.map((l: any, i: number) => (
            <tr key={l.id} className={editable ? 'cursor-pointer hover:bg-slate-50' : ''} onClick={() => editable && setLine({ ...l, description_ar: l.description_ar ?? '', vat_exemption_reason: l.vat_exemption_reason ?? '' })}>
              <td className="td">{i + 1}</td>
              <td className="td">{l.description_en}{l.description_ar && <div className="text-xs text-slate-500" dir="rtl">{l.description_ar}</div>}
                {l.vat_category !== 'S' && <div className="text-xs text-amber-700">{l.vat_code}: {l.vat_exemption_reason || t('inv.needsReason')}</div>}</td>
              <td className="td">{l.unit}</td><td className="td num">{num(l.quantity)}</td><td className="td num">{num(l.unit_price, 4)}</td>
              <td className="td num">{Number(l.discount_amount) ? money(l.discount_amount) : '—'}</td><td className="td num">{money(l.net_amount)}</td>
              <td className="td num">{money(l.vat_amount)} <span className="text-xs text-slate-400">{Number(l.vat_rate)}%</span></td>
              <td className="td num">{money(Number(l.net_amount) + Number(l.vat_amount))}</td>
              <td className="td">{editable && <button className="text-slate-400 hover:text-red-600" onClick={(e) => { e.stopPropagation(); delLine.mutate(l.id); }}><Trash2 className="h-4 w-4" /></button>}</td>
            </tr>))}</tbody></table></div>}
      </Card>

      {inv.status === 'issued' && ['invoice', 'debit_note'].includes(inv.kind) && (
        <Card title={t('inv.payments')} bodyClass="p-0" actions={can('payments.write') && balance > 0 &&
          <Button onClick={() => setPay({ payment_date: new Date().toISOString().slice(0, 10), amount: balance.toFixed(2), method: 'bank_transfer', reference: '' })}><Plus className="h-4 w-4" />{t('inv.recordPayment')}</Button>}>
          {!inv.payments.length ? <Empty /> : <table className="w-full"><tbody className="divide-y">{inv.payments.map((p: any) => (
            <tr key={p.id} className={p.voided_at ? 'text-slate-400 line-through' : ''}>
              <td className="td font-mono text-xs">{p.number}</td><td className="td">{date(p.payment_date)}</td><td className="td">{t(`inv.method.${p.method}`)}</td>
              <td className="td">{p.reference}</td><td className="td num">{money(p.amount, inv.currency)}</td>
              <td className="td">{!p.voided_at && can('payments.write') && <button className="link text-xs" onClick={() => {
                const reason = window.prompt(t('inv.voidReason')); if (reason) voidPay.mutate({ pid: p.id, reason }); }}>{t('inv.void')}</button>}
                {p.voided_at && <span className="text-xs no-underline">{p.void_reason}</span>}</td>
            </tr>))}</tbody></table>}
        </Card>
      )}

      {inv.notes.length > 0 && <Card title={t('inv.notesAgainst')} bodyClass="p-0"><table className="w-full"><tbody className="divide-y">{inv.notes.map((n: any) => (
        <tr key={n.id}><td className="td"><Link className="link" to={`/invoices/${n.id}`}>{n.number ?? t('inv.status.draft')}</Link></td><td className="td">{t(`inv.kind.${n.kind}`)}</td>
          <td className="td">{n.note_reason}</td><td className="td num">{money(n.total_amount)}</td><td className="td"><Badge tone={STATUS_TONES[n.status]}>{t(`inv.status.${n.status}`)}</Badge></td></tr>))}</tbody></table></Card>}

      <Modal open={!!line} onClose={() => setLine(null)} title={line?.id ? t('inv.editLine') : t('inv.addLine')} wide
        footer={<Button busy={saveLine.isPending} onClick={() => saveLine.mutate(line)} data-testid="save-line">{t('common.save')}</Button>}>
        {line && <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('inv.descEn')} className="sm:col-span-2"><Textarea value={line.description_en} onChange={(e) => setLine({ ...line, description_en: e.target.value })} name="description_en" /></Field>
          <Field label={t('inv.descAr')} className="sm:col-span-2"><Textarea dir="rtl" value={line.description_ar} onChange={(e) => setLine({ ...line, description_ar: e.target.value })} /></Field>
          <Field label={t('inv.unit')}><Input value={line.unit} onChange={(e) => setLine({ ...line, unit: e.target.value })} /></Field>
          <Field label={t('inv.qty')}><Input type="number" step="any" value={line.quantity} onChange={(e) => setLine({ ...line, quantity: e.target.value })} name="quantity" /></Field>
          <Field label={t('inv.price')}><Input type="number" step="any" value={line.unit_price} onChange={(e) => setLine({ ...line, unit_price: e.target.value })} name="unit_price" /></Field>
          <Field label={t('inv.discount')}><Input type="number" step="any" value={line.discount_amount} onChange={(e) => setLine({ ...line, discount_amount: e.target.value })} /></Field>
          <Field label={t('inv.vatCode')}><Select value={line.vat_code} onChange={(e) => setLine({ ...line, vat_code: e.target.value })}>
            {(vat.data?.vat_codes ?? []).map((v: any) => <option key={v.code} value={v.code}>{pick(v.name_en, v.name_ar)}</option>)}</Select></Field>
          {line.vat_code !== 'S15' && <Field label={t('inv.exemptReason')}><Input value={line.vat_exemption_reason} onChange={(e) => setLine({ ...line, vat_exemption_reason: e.target.value })} /></Field>}
        </div>}
      </Modal>

      <Modal open={!!pay} onClose={() => setPay(null)} title={t('inv.recordPayment')} footer={<Button busy={addPay.isPending} onClick={() => addPay.mutate()}>{t('common.save')}</Button>}>
        {pay && <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('common.date')}><Input type="date" value={pay.payment_date} onChange={(e) => setPay({ ...pay, payment_date: e.target.value })} /></Field>
          <Field label={t('inv.amount')}><Input type="number" step="0.01" value={pay.amount} onChange={(e) => setPay({ ...pay, amount: e.target.value })} /></Field>
          <Field label={t('inv.methodLabel')}><Select value={pay.method} onChange={(e) => setPay({ ...pay, method: e.target.value })}>
            {['bank_transfer', 'cheque', 'cash', 'card', 'other'].map((m) => <option key={m} value={m}>{t(`inv.method.${m}`)}</option>)}</Select></Field>
          <Field label={t('inv.reference')}><Input value={pay.reference} onChange={(e) => setPay({ ...pay, reference: e.target.value })} /></Field>
        </div>}
      </Modal>

      <Modal open={confirmIssue} onClose={() => setConfirmIssue(false)} title={t('inv.issue')}
        footer={<Button busy={issue.isPending} onClick={() => issue.mutate()} data-testid="confirm-issue">{t('inv.issueConfirm')}</Button>}>
        <p className="text-sm">{t('inv.issueWarning')}</p>
        <p className="mt-2 text-sm font-semibold">{t('inv.total')}: {money(inv.total_amount, inv.currency)}</p>
      </Modal>

      <Modal open={cancel !== null} onClose={() => setCancel(null)} title={t('inv.cancel')}
        footer={<Button variant="danger" busy={doCancel.isPending} disabled={!cancel} onClick={() => doCancel.mutate()}>{t('inv.cancel')}</Button>}>
        <Field label={t('inv.reason')}><Textarea value={cancel ?? ''} onChange={(e) => setCancel(e.target.value)} /></Field>
      </Modal>
    </div>
  );
}

/** "Bill progress" on a contract: creates a draft progress-claim invoice for a percentage of the contract value. */
export function BillContract({ contract }: { contract: any }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const toast = useToast();
  const [percent, setPercent] = useState<string | null>(null);
  const m = useMutation({
    mutationFn: () => api.post(`/contracts/${contract.id}/invoices`, { percent }),
    onSuccess: (inv) => nav(`/invoices/${inv.id}`), onError: (e: Error) => toast(e.message, 'error'),
  });
  return <>
    <button className="link text-xs" onClick={() => setPercent('10')}>{t('inv.billProgress')}</button>
    <Modal open={percent !== null} onClose={() => setPercent(null)} title={`${t('inv.billProgress')} — ${contract.number}`}
      footer={<Button busy={m.isPending} onClick={() => m.mutate()}>{t('common.create')}</Button>}>
      <Field label={t('inv.percentOfContract')} hint={money(contract.original_value, contract.currency)}>
        <Input type="number" min="0.01" max="100" step="0.01" value={percent ?? ''} onChange={(e) => setPercent(e.target.value)} /></Field>
    </Modal>
  </>;
}
