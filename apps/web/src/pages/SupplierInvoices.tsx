// Supplier invoices (bills) matched against the purchase order and goods received, posted to payables, and paid.
import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Check, Plus, Trash2, X } from 'lucide-react';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { date, money, num, pick } from '../lib/format';
import { Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Select, Spinner, cx, useToast } from '../components/ui';
import { Approvals, Row, Status, today, useLookups, useReason } from '../components/fin';
import Attachments from '../components/Attachments';

export function SupplierInvoices() {
  const { t } = useTranslation();
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('');
  const [tab, setTab] = useState<'bills' | 'payments'>('bills');
  const bills = useQuery({ queryKey: ['supplier-invoices', q, status], queryFn: () => api.get(`/supplier-invoices${qs({ q, status: status === 'unpaid' ? undefined : status, unpaid: status === 'unpaid' || undefined })}`), enabled: tab === 'bills' });
  const pays = useQuery({ queryKey: ['supplier-payments', q], queryFn: () => api.get(`/supplier-payments${qs({ q })}`), enabled: tab === 'payments' });
  const list = tab === 'bills' ? bills : pays;
  return (
    <div>
      <PageHeader title={t('fin.supplierInvoices')} subtitle={t('fin.supplierInvoicesHint')} actions={<>
        <Input className="w-56" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
        {tab === 'bills' && <Select className="w-40" value={status} onChange={(e) => setStatus(e.target.value)}>
          <option value="">{t('common.all')}</option>{['draft', 'posted', 'unpaid', 'cancelled'].map((s) => <option key={s} value={s}>{t(`fin.status.${s}`)}</option>)}
        </Select>}
      </>} />
      <div className="mb-3 inline-flex overflow-hidden rounded-md border bg-white text-sm">
        {(['bills', 'payments'] as const).map((k) => (
          <button key={k} className={cx('px-3 py-1.5', tab === k ? 'bg-brand-50 font-medium text-brand-800' : 'text-slate-600 hover:bg-slate-50')} onClick={() => setTab(k)}>{t(`fin.tab.${k}`)}</button>
        ))}
      </div>
      <Card bodyClass="p-0">
        {list.isLoading ? <Spinner /> : list.error ? <ErrorBox error={list.error} /> : !list.data?.length ? <Empty>{tab === 'bills' ? t('fin.billsFromPo') : undefined}</Empty> : tab === 'bills' ? (
          <div className="overflow-x-auto"><table className="w-full text-sm"><thead className="bg-slate-50"><tr>
            <th className="th">{t('common.number')}</th><th className="th">{t('fin.supplierInvoiceNo')}</th><th className="th">{t('pur.supplier')}</th><th className="th">{t('fin.po')}</th>
            <th className="th">{t('common.status')}</th><th className="th">{t('fin.dueDate')}</th><th className="th text-end">{t('common.total')}</th><th className="th text-end">{t('fin.openAmount')}</th>
          </tr></thead><tbody className="divide-y">
            {list.data.map((b: any) => (
              <tr key={b.id}>
                <td className="td font-mono text-xs"><Link className="link" to={`/supplier-invoices/${b.id}`}>{b.number ?? t('pur.draft')}</Link></td>
                <td className="td">{b.supplier_invoice_number}</td><td className="td">{b.supplier_name}</td><td className="td font-mono text-xs">{b.po_number}</td>
                <td className="td"><Status value={b.status} /> {b.match_status && b.match_status !== 'matched' && <Status value={b.match_status} />}</td>
                <td className="td">{date(b.due_date)}</td><td className="td num">{money(b.total_amount)}</td>
                <td className="td num">{b.status === 'posted' ? money(Number(b.amount_payable) - Number(b.amount_paid)) : ''}</td>
              </tr>
            ))}
          </tbody></table></div>
        ) : (
          <table className="w-full text-sm"><thead className="bg-slate-50"><tr>
            <th className="th">{t('common.number')}</th><th className="th">{t('common.date')}</th><th className="th">{t('pur.supplier')}</th><th className="th">{t('common.type')}</th>
            <th className="th">{t('fin.reference')}</th><th className="th text-end">{t('fin.amount')}</th>
          </tr></thead><tbody className="divide-y">
            {list.data.map((p: any) => (
              <tr key={p.id} className={p.voided_at ? 'text-slate-400 line-through' : ''}>
                <td className="td font-mono text-xs">{p.number}</td><td className="td">{date(p.payment_date)}</td><td className="td">{p.supplier_name}</td>
                <td className="td">{t(`fin.payKind.${p.kind}`)} {p.invoice_id ? <Link className="link" to={`/supplier-invoices/${p.invoice_id}`}>{p.invoice_number}</Link> : p.po_number}</td>
                <td className="td">{p.reference}</td><td className="td num">{money(p.amount)}</td>
              </tr>
            ))}
          </tbody></table>
        )}
      </Card>
    </div>
  );
}

export function SupplierInvoiceDetail() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const reason = useReason();
  const lookups = useLookups();
  const { data: b, isLoading, error } = useQuery({ queryKey: ['supplier-invoice', id], queryFn: () => api.get(`/supplier-invoices/${id}`) });
  const [pay, setPay] = useState<any>(null);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['supplier-invoice', id] }); qc.invalidateQueries({ queryKey: ['supplier-invoices'] }); };
  const onError = (e: Error) => { toast(e.message, 'error'); refresh(); };
  const patch = (body: any) => api.patch(`/supplier-invoices/${id}`, body).then(refresh, onError);
  const post = (override_comment?: string) => api.post(`/supplier-invoices/${id}/post`, override_comment ? { override_comment } : {}).then(() => { refresh(); toast(t('fin.posted')); }, onError);
  const doPay = useMutation({
    mutationFn: () => api.post('/supplier-payments', { invoice_id: id, ...pay, reference: pay.reference || undefined }),
    onSuccess: () => { setPay(null); refresh(); toast(t('common.saved')); }, onError,
  });

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const draft = b.status === 'draft';
  const editable = draft && can('procurement.order');
  const m = b.match;
  const variance = m?.status === 'variance';
  const open = Number(b.amount_payable) - Number(b.amount_paid);
  const field = (k: string, type = 'text') => (
    <Input type={type} name={k} disabled={!editable} defaultValue={b[k] ?? ''} key={`${k}-${b.updated_at}`}
      onBlur={(e) => { if ((e.target.value || null) !== (b[k] ?? null)) patch({ [k]: e.target.value || null }); }} />
  );
  return (
    <div className="space-y-4">
      <PageHeader
        title={<span className="flex flex-wrap items-center gap-2">{t('fin.supplierInvoice')} {b.number && <span className="font-mono">{b.number}</span>}<Status value={b.status} />{m && <Status value={m.status} />}</span>}
        subtitle={<>{pick(b.supplier_name, b.supplier_name_ar)} · {t('fin.theirRef')} <b>{b.supplier_invoice_number}</b>
          {b.po_number && <> · <Link className="link" to={`/purchases/orders/${b.po_id}`}>{b.po_number}</Link></>}
          {b.project_number && <> · <Link className="link" to={`/projects/${b.project_id}`}>{b.project_number}</Link></>}</>}
        actions={<>
          {draft && (can('procurement.order') || can('payments.write')) && (variance
            ? can('procurement.approve') && <Button variant="danger" onClick={() => reason.ask(t('fin.postWithVariance'), (c) => post(c), { label: t('fin.varianceReason') })}>{t('fin.postWithVariance')}</Button>
            : <Button onClick={() => post()} data-testid="post-bill">{t('fin.postToPayables')}</Button>)}
          {b.status === 'posted' && open > 0 && can('payments.write') && <Button data-testid="pay-bill" onClick={() => setPay({ kind: 'invoice', payment_date: today(), amount: open.toFixed(2), bank_account_code: '1010', method: 'bank_transfer', reference: '' })}>{t('fin.recordPayment')}</Button>}
          {b.status === 'posted' && Number(b.retention_amount) > Number(b.retention_released) && can('payments.write') && <Button variant="secondary" onClick={() => setPay({ kind: 'retention', payment_date: today(), amount: (Number(b.retention_amount) - Number(b.retention_released)).toFixed(2), bank_account_code: '1010', method: 'bank_transfer', reference: '' })}>{t('fin.releaseRetention')}</Button>}
          {b.status !== 'cancelled' && can('procurement.order') && <Button variant="ghost" onClick={() => reason.ask(t('common.cancel'), (r) => api.post(`/supplier-invoices/${id}/cancel`, { reason: r }).then(refresh, onError), { danger: true, label: t('inv.reason') })}>{t('common.cancel')}</Button>}
        </>} />
      {variance && <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-900" data-testid="variance-banner">{t('fin.varianceHint')}</div>}
      <div className="grid gap-4 lg:grid-cols-3">
        <Card title={t('pur.items')} bodyClass="p-0" className="lg:col-span-2">
          <BillLines bill={b} editable={editable} refresh={refresh} onError={onError} />
        </Card>
        <div className="space-y-4">
          <Card title={t('inv.totals')}>
            <dl className="space-y-1.5 text-sm">
              <Row label={t('inv.subtotal')}>{money(b.subtotal)}</Row>
              <Row label={t('inv.vat')}>{money(b.vat_total)}</Row>
              <Row label={t('common.total')} strong testId="bill-total">{money(b.total_amount)}</Row>
              {Number(b.retention_amount) > 0 && <Row label={t('fin.retentionKept')}>− {money(b.retention_amount)}</Row>}
              {Number(b.advance_recovery) > 0 && <Row label={t('fin.advanceRecovered')}>− {money(b.advance_recovery)}</Row>}
              <Row label={t('fin.payable')} strong testId="bill-payable">{money(b.amount_payable)}</Row>
              <Row label={t('fin.paid')}>{money(b.amount_paid)}</Row>
              <Row label={t('fin.openAmount')} testId="bill-open">{money(open)}</Row>
            </dl>
          </Card>
          <Approvals info={b.approvals} />
        </div>
      </div>
      {m && m.status !== 'no_po' && (
        <Card title={t('fin.threeWayMatch')} bodyClass="p-0">
          <table className="w-full text-sm" data-testid="match-table"><thead className="bg-slate-50"><tr>
            <th className="th">{t('pur.item')}</th><th className="th text-end">{t('fin.ordered')}</th><th className="th text-end">{t('fin.receivedQty')}</th>
            <th className="th text-end">{t('fin.invoicedBefore')}</th><th className="th text-end">{t('fin.thisInvoice')}</th><th className="th text-end">{t('fin.poPrice')}</th>
            <th className="th text-end">{t('fin.invoicePrice')}</th><th className="th" />
          </tr></thead><tbody className="divide-y">
            {m.lines.map((l: any, i: number) => (
              <tr key={i} className={!l.qty_ok || !l.price_ok ? 'bg-red-50/60' : ''}>
                <td className="td">{l.description}</td><td className="td num">{num(l.ordered_qty)}</td><td className="td num">{num(l.received_qty)}</td>
                <td className="td num">{num(l.invoiced_before)}</td><td className={cx('td num', !l.qty_ok && 'font-semibold text-red-700')}>{num(l.invoiced_qty)}</td>
                <td className="td num">{money(l.po_price)}</td><td className={cx('td num', !l.price_ok && 'font-semibold text-red-700')}>{money(l.invoice_price)}</td>
                <td className="td">{l.qty_ok && l.price_ok ? <Check className="h-4 w-4 text-emerald-600" /> : <X className="h-4 w-4 text-red-600" />}</td>
              </tr>
            ))}
          </tbody></table>
          {m.po_amount && <div className="border-t px-4 py-2 text-xs text-slate-500">{t('fin.poValue')} {money(m.po_amount)} · {t('fin.billedBefore')} {money(m.billed_before)} · {t('fin.thisInvoice')} {money(m.this_invoice)}</div>}
        </Card>
      )}
      <div className="grid gap-4 lg:grid-cols-2">
        <Card title={t('inv.details')}>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label={t('fin.supplierInvoiceNo')}>{field('supplier_invoice_number')}</Field>
            <Field label={t('fin.invoiceDate')}>{field('invoice_date', 'date')}</Field>
            <Field label={t('fin.dueDate')}>{field('due_date', 'date')}</Field>
            <Field label={t('fin.retentionPct')}>{field('retention_pct', 'number')}</Field>
            <Field label={t('fin.advanceRecovery')} hint={`${t('fin.advanceOpen')}: ${money(b.advance_open)}`}>{field('advance_recovery', 'number')}</Field>
            <Field label={t('common.notes')}>{field('notes')}</Field>
          </div>
        </Card>
        <Card title={t('fin.payments')} bodyClass="p-0">
          {!b.payments.length ? <Empty /> : <table className="w-full text-sm"><tbody className="divide-y">
            {b.payments.map((p: any) => (
              <tr key={p.id} className={p.voided_at ? 'text-slate-400 line-through' : ''}>
                <td className="td font-mono text-xs">{p.number}</td><td className="td">{date(p.payment_date)} · {t(`fin.payKind.${p.kind}`)}</td><td className="td">{p.reference}</td>
                <td className="td num">{money(p.amount)}</td>
                <td className="td">{!p.voided_at && can('payments.write') && <button className="link text-xs" onClick={() => reason.ask(t('fin.voidPayment'), (r) => api.post(`/supplier-payments/${p.id}/void`, { reason: r }).then(refresh, onError), { danger: true })}>{t('fin.void')}</button>}</td>
              </tr>
            ))}
          </tbody></table>}
        </Card>
      </div>
      <Attachments entityType="supplier_invoice" entityId={b.id} canWrite={can('procurement.order') || can('payments.write')} />
      <Modal open={!!pay} onClose={() => setPay(null)} title={pay?.kind === 'retention' ? t('fin.releaseRetention') : t('fin.recordPayment')}
        footer={<Button busy={doPay.isPending} onClick={() => doPay.mutate()} data-testid="pay-confirm">{t('common.confirm')}</Button>}>
        <ErrorBox error={doPay.error} />
        {pay && <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('common.date')}><Input type="date" value={pay.payment_date} onChange={(e) => setPay({ ...pay, payment_date: e.target.value })} /></Field>
          <Field label={t('fin.amount')}><Input name="amount" type="number" step="any" value={pay.amount} onChange={(e) => setPay({ ...pay, amount: e.target.value })} /></Field>
          <Field label={t('fin.paidFrom')}><Select name="bank_account_code" value={pay.bank_account_code} onChange={(e) => setPay({ ...pay, bank_account_code: e.target.value })}>
            {lookups.data?.bank_accounts.map((a: any) => <option key={a.code} value={a.code}>{a.code} · {pick(a.name_en, a.name_ar)}</option>)}</Select></Field>
          <Field label={t('fin.method')}><Select value={pay.method} onChange={(e) => setPay({ ...pay, method: e.target.value })}>
            {['bank_transfer', 'cheque', 'cash', 'card', 'other'].map((x) => <option key={x} value={x}>{t(`fin.methods.${x}`)}</option>)}</Select></Field>
          <Field label={t('fin.reference')} className="sm:col-span-2"><Input value={pay.reference} onChange={(e) => setPay({ ...pay, reference: e.target.value })} /></Field>
        </div>}
      </Modal>
      {reason.modal}
    </div>
  );
}

function BillLines({ bill, editable, refresh, onError }: { bill: any; editable: boolean; refresh: () => void; onError: (e: Error) => void }) {
  const { t } = useTranslation();
  const blank = { po_line_id: '', description: '', unit: 'LS', quantity: '1', unit_price: '' };
  const [row, setRow] = useState<any>(blank);
  const cell = 'w-full rounded border border-transparent bg-transparent px-1 py-0.5 hover:border-slate-300 focus:border-brand-500 focus:bg-white focus:outline-none';
  const edit = (l: any, k: string, cls = '') => editable
    ? <input className={cx(cell, cls)} defaultValue={l[k] ?? ''} key={`${l.id}-${k}-${l.updated_at}`} type={['description', 'unit'].includes(k) ? 'text' : 'number'} step="any"
        onBlur={(e) => { if (e.target.value !== String(l[k] ?? '')) api.patch(`/supplier-invoice-lines/${l.id}`, { [k]: e.target.value }).then(refresh, onError); }} />
    : <span className={cx('block px-1', cls)}>{k === 'quantity' ? num(l[k]) : k === 'unit_price' ? money(l[k]) : l[k]}</span>;
  const pickPoLine = (lineId: string) => {
    const pl = bill.po_lines?.find((x: any) => x.id === lineId);
    setRow(pl ? { po_line_id: pl.id, description: pl.description, unit: pl.unit, quantity: String(Math.max(Number(pl.received_qty) - Number(pl.invoiced_qty), 0)), unit_price: pl.unit_cost } : { ...blank });
  };
  const add = () => row.description.trim() && api.post(`/supplier-invoices/${bill.id}/lines`, { ...row, po_line_id: row.po_line_id || undefined }).then(() => { setRow(blank); refresh(); }, onError);
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[560px] text-sm"><thead className="bg-slate-50"><tr>
        <th className="th">{t('pur.item')}</th><th className="th w-16">{t('quote.unit')}</th><th className="th w-24 text-end">{t('quote.qty')}</th>
        <th className="th w-32 text-end">{t('pur.unitPrice')}</th><th className="th w-32 text-end">{t('fin.amountExVat')}</th>{editable && <th className="w-8" />}
      </tr></thead><tbody className="divide-y">
        {bill.lines.map((l: any) => (
          <tr key={l.id}>
            <td className="px-2 py-1">{edit(l, 'description')}</td><td className="px-2 py-1">{edit(l, 'unit')}</td>
            <td className="px-2 py-1">{edit(l, 'quantity', 'text-end tabular-nums')}</td><td className="px-2 py-1">{edit(l, 'unit_price', 'text-end tabular-nums')}</td>
            <td className="px-2 py-1 text-end font-medium tabular-nums">{money(l.net_amount)}</td>
            {editable && <td className="px-1"><button aria-label={t('common.delete')} className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600"
              onClick={() => api.del(`/supplier-invoice-lines/${l.id}`).then(refresh, onError)}><Trash2 className="h-4 w-4" /></button></td>}
          </tr>
        ))}
        {editable && (
          <tr className="bg-slate-50/60">
            <td className="px-2 py-1">
              {bill.po_lines?.length > 0 && <Select className="mb-1" value={row.po_line_id} onChange={(e) => pickPoLine(e.target.value)}>
                <option value="">{t('fin.lineNotOnPo')}</option>{bill.po_lines.map((pl: any) => <option key={pl.id} value={pl.id}>{pl.description}</option>)}</Select>}
              <Input placeholder={t('pur.addItem')} value={row.description} onChange={(e) => setRow({ ...row, description: e.target.value })} />
            </td>
            <td className="px-2 py-1"><Input value={row.unit} onChange={(e) => setRow({ ...row, unit: e.target.value })} /></td>
            <td className="px-2 py-1"><Input type="number" step="any" className="text-end" value={row.quantity} onChange={(e) => setRow({ ...row, quantity: e.target.value })} /></td>
            <td className="px-2 py-1"><Input type="number" step="any" className="text-end" value={row.unit_price} onChange={(e) => setRow({ ...row, unit_price: e.target.value })} /></td>
            <td className="px-2 py-1 text-end" colSpan={2}><Button variant="secondary" onClick={add}><Plus className="h-4 w-4" />{t('common.add')}</Button></td>
          </tr>
        )}
      </tbody></table>
    </div>
  );
}
