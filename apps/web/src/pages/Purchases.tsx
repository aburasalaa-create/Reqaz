// Purchases: purchase orders to suppliers and internal purchase requests. Totals always come from the server.
import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { FileDown, Plus, Trash2 } from 'lucide-react';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { date, money, num, pick } from '../lib/format';
import { Badge, Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Select, Spinner, Textarea, cx, useToast, type Tone } from '../components/ui';
import { Approvals, Row, Status, catName, today, useLookups, useReason } from '../components/fin';
import Attachments from '../components/Attachments';

const TONES: Record<string, Tone> = {
  draft: 'slate', submitted: 'amber', approved: 'green', rejected: 'red', ordered: 'blue', cancelled: 'red',
  issued: 'green', received: 'blue', closed: 'slate', pending_approval: 'amber', partially_received: 'amber', superseded: 'slate',
};

// Pick an existing supplier or type a new name (and VAT number); a new supplier is created when the order is.
type SupplierChoice = { id: string; name: string; vat?: string };
function SupplierPicker({ value, onChange }: { value: SupplierChoice; onChange: (v: SupplierChoice) => void }) {
  const { t } = useTranslation();
  const { data = [] } = useQuery({ queryKey: ['suppliers', 'select'], queryFn: () => api.get('/suppliers?limit=500') });
  return (
    <div className="grid gap-2">
      <Select name="supplier_id" value={value.id} onChange={(e) => onChange({ id: e.target.value, name: '' })}>
        <option value="">{t('pur.newSupplier')}</option>
        {data.map((s: any) => <option key={s.id} value={s.id}>{pick(s.name_en, s.name_ar)}</option>)}
      </Select>
      {!value.id && <Input name="supplier_name" placeholder={t('pur.supplierName')} value={value.name} onChange={(e) => onChange({ ...value, name: e.target.value })} />}
      {!value.id && <Input name="supplier_vat" placeholder={t('fin.supplierVat')} value={value.vat ?? ''} onChange={(e) => onChange({ ...value, vat: e.target.value.trim() })} />}
    </div>
  );
}

const supplierId = async (v: SupplierChoice, t: (k: string) => string) => {
  if (v.id) return v.id;
  if (!v.name.trim()) throw new Error(t('pur.pickSupplier'));
  return (await api.post('/suppliers', { name_en: v.name.trim(), vat_number: v.vat || undefined })).id as string;
};

export function Purchases() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const nav = useNavigate();
  const [tab, setTab] = useState<'orders' | 'requests'>('orders');
  const [q, setQ] = useState('');
  const [newPo, setNewPo] = useState<{ id: string; name: string } | null>(null);
  const [newPr, setNewPr] = useState<string | null>(null);
  const orders = useQuery({ queryKey: ['purchase-orders', q], queryFn: () => api.get(`/purchase-orders${qs({ q })}`), enabled: tab === 'orders' });
  const requests = useQuery({ queryKey: ['purchase-requests', q], queryFn: () => api.get(`/purchase-requests${qs({ q })}`), enabled: tab === 'requests' });
  const createPo = useMutation({
    mutationFn: async () => api.post('/purchase-orders', { supplier_id: await supplierId(newPo!, t) }),
    onSuccess: (po) => nav(`/purchases/orders/${po.id}`),
  });
  const createPr = useMutation({ mutationFn: () => api.post('/purchase-requests', { title: newPr }), onSuccess: (pr) => nav(`/purchases/requests/${pr.id}`) });
  const list = tab === 'orders' ? orders : requests;

  return (
    <div>
      <PageHeader title={t('nav.purchases')} actions={<>
        <Input className="w-56" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
        {can('procurement.request') && <Button variant="secondary" onClick={() => setNewPr('')}><Plus className="h-4 w-4" />{t('pur.newRequest')}</Button>}
        {can('procurement.order') && <Button onClick={() => setNewPo({ id: '', name: '' })}><Plus className="h-4 w-4" />{t('pur.newOrder')}</Button>}
      </>} />
      <div className="mb-3 inline-flex overflow-hidden rounded-md border bg-white text-sm">
        {(['orders', 'requests'] as const).map((k) => (
          <button key={k} className={cx('px-3 py-1.5', tab === k ? 'bg-brand-50 font-medium text-brand-800' : 'text-slate-600 hover:bg-slate-50')} onClick={() => setTab(k)}>{t(`pur.${k}`)}</button>
        ))}
      </div>
      <Card bodyClass="p-0">
        {list.isLoading ? <Spinner /> : list.error ? <ErrorBox error={list.error} /> : !list.data?.length ? <Empty /> : (
          <table className="w-full text-sm"><thead className="bg-slate-50"><tr>
            <th className="th">{t('common.number')}</th><th className="th">{tab === 'orders' ? t('pur.supplier') : t('common.title')}</th>
            <th className="th">{t('common.status')}</th><th className="th">{t('common.date')}</th><th className="th text-end">{t('common.total')}</th>
          </tr></thead><tbody className="divide-y">
            {list.data.map((x: any) => (
              <tr key={x.id}>
                <td className="td font-mono text-xs"><Link className="link" to={`/purchases/${tab}/${x.id}`}>{x.number ?? t('pur.draft')}</Link></td>
                <td className="td">{tab === 'orders' ? pick(x.supplier_name, x.supplier_name_ar) : x.title}{x.project_number && <span className="text-xs text-slate-400"> · {x.project_number}</span>}</td>
                <td className="td"><Badge tone={TONES[x.status]}>{t(`pur.status.${x.status}`)}</Badge></td>
                <td className="td">{date(x.issue_date ?? x.needed_by ?? x.created_at)}</td>
                <td className="td num">{money(x.total_amount ?? x.estimated_total, x.currency)}</td>
              </tr>
            ))}
          </tbody></table>
        )}
      </Card>

      <Modal open={!!newPo} onClose={() => setNewPo(null)} title={t('pur.newOrder')}
        footer={<><Button variant="secondary" onClick={() => setNewPo(null)}>{t('common.cancel')}</Button><Button busy={createPo.isPending} onClick={() => createPo.mutate()}>{t('common.create')}</Button></>}>
        <ErrorBox error={createPo.error} />
        {newPo && <Field label={t('pur.supplier')}><SupplierPicker value={newPo} onChange={setNewPo} /></Field>}
      </Modal>
      <Modal open={newPr !== null} onClose={() => setNewPr(null)} title={t('pur.newRequest')}
        footer={<><Button variant="secondary" onClick={() => setNewPr(null)}>{t('common.cancel')}</Button><Button busy={createPr.isPending} onClick={() => createPr.mutate()}>{t('common.create')}</Button></>}>
        <ErrorBox error={createPr.error} />
        <Field label={t('pur.whatFor')}><Input name="title" value={newPr ?? ''} onChange={(e) => setNewPr(e.target.value)} /></Field>
      </Modal>
    </div>
  );
}

// Items table shared by orders and requests. Drafts edit in place; a new item is typed in the last row.
function Items({ lines, editable, price, onAdd, onPatch, onDelete, currency }: {
  lines: any[]; editable: boolean; price: 'unit_price' | 'estimated_unit_cost'; currency: string;
  onAdd: (b: any) => Promise<unknown>; onPatch: (id: string, b: any) => void; onDelete: (id: string) => void;
}) {
  const { t } = useTranslation();
  const blank = { description: '', unit: 'pcs', quantity: '1', [price]: '' };
  const [row, setRow] = useState<any>(blank);
  const cellCls = 'w-full rounded border border-transparent bg-transparent px-1 py-0.5 hover:border-slate-300 focus:border-brand-500 focus:bg-white focus:outline-none';
  const edit = (l: any, k: string, cls = '') => editable
    ? <input className={cx(cellCls, cls)} defaultValue={l[k] ?? ''} key={`${l.id}-${k}-${l.updated_at}`} type={k === 'description' || k === 'unit' ? 'text' : 'number'} step="any"
        onBlur={(e) => { if (e.target.value !== String(l[k] ?? '')) onPatch(l.id, { [k]: e.target.value }); }} />
    : <span className={cx('block px-1', cls)}>{k === 'quantity' ? num(l[k], 3) : k === price ? money(l[k]) : l[k]}</span>;
  const total = (l: any) => price === 'unit_price' ? Number(l.net_amount) + Number(l.vat_amount) : l.estimated_total;
  const add = async () => {
    if (!row.description.trim()) return;
    await onAdd({ ...row, [price]: row[price] === '' ? undefined : row[price] });
    setRow(blank);
  };
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[560px] text-sm">
        <thead className="bg-slate-50"><tr>
          <th className="th">{t('pur.item')}</th><th className="th w-20">{t('quote.unit')}</th><th className="th w-24 text-end">{t('quote.qty')}</th>
          <th className="th w-32 text-end">{price === 'unit_price' ? t('pur.unitPrice') : t('pur.estCost')}</th>
          <th className="th w-32 text-end">{price === 'unit_price' ? t('pur.totalInclVat') : t('common.total')}</th>{editable && <th className="w-8" />}
        </tr></thead>
        <tbody className="divide-y">
          {lines.map((l) => (
            <tr key={l.id}>
              <td className="px-2 py-1">{edit(l, 'description')}</td><td className="px-2 py-1">{edit(l, 'unit')}</td>
              <td className="px-2 py-1">{edit(l, 'quantity', 'text-end tabular-nums')}</td><td className="px-2 py-1">{edit(l, price, 'text-end tabular-nums')}</td>
              <td className="px-2 py-1 text-end font-medium tabular-nums">{money(total(l))}</td>
              {editable && <td className="px-1"><button aria-label={t('common.delete')} className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600" onClick={() => onDelete(l.id)}><Trash2 className="h-4 w-4" /></button></td>}
            </tr>
          ))}
          {editable && (
            <tr className="bg-slate-50/60">
              <td className="px-2 py-1"><Input name="new_description" placeholder={t('pur.addItem')} value={row.description} onChange={(e) => setRow({ ...row, description: e.target.value })} onKeyDown={(e) => e.key === 'Enter' && add()} /></td>
              <td className="px-2 py-1"><Input name="new_unit" value={row.unit} onChange={(e) => setRow({ ...row, unit: e.target.value })} /></td>
              <td className="px-2 py-1"><Input name="new_quantity" type="number" step="any" className="text-end" value={row.quantity} onChange={(e) => setRow({ ...row, quantity: e.target.value })} /></td>
              <td className="px-2 py-1"><Input name="new_price" type="number" step="any" className="text-end" value={row[price]} onChange={(e) => setRow({ ...row, [price]: e.target.value })} onKeyDown={(e) => e.key === 'Enter' && add()} /></td>
              <td className="px-2 py-1 text-end" colSpan={2}><Button variant="secondary" onClick={add} data-testid="add-item"><Plus className="h-4 w-4" />{t('common.add')}</Button></td>
            </tr>
          )}
        </tbody>
      </table>
      {!lines.length && !editable && <Empty />}
      <span className="sr-only">{currency}</span>
    </div>
  );
}

const useProjects = () => useQuery({ queryKey: ['projects'], queryFn: () => api.get('/projects'), staleTime: 60_000 });

/** The budget check stored when an order or request was sent for approval. */
function BudgetCheck({ check }: { check: any }) {
  const { t } = useTranslation();
  const lookups = useLookups();
  const cats = check?.categories ?? (check ? [check] : []);
  if (!cats.length) return null;
  return (
    <Card title={t('fin.budgetCheck')}>
      {cats.map((c: any) => (
        <dl key={c.cost_category} className="mb-2 space-y-1 text-sm last:mb-0">
          <div className="font-medium">{catName(lookups.data?.cost_categories, c.cost_category)}</div>
          <Row label={t('fin.budget')}>{money(c.budget)}</Row>
          <Row label={t('fin.actualCost')}>{money(c.actual)}</Row>
          <Row label={t('fin.committed')}>{money(c.committed)}</Row>
          {Number(c.unallocated) > 0 && <Row label={t('fin.unallocated')}>{money(c.unallocated)}</Row>}
          <Row label={t('fin.available')}>{money(c.available)}</Row>
          <Row label={t('fin.thisRequest')} strong>{money(c.requested)}</Row>
          <div className={cx('text-xs font-medium', c.over_budget ? 'text-red-700' : 'text-emerald-700')} data-testid="budget-result">
            {c.over_budget ? t('fin.overBudget') : t('fin.withinBudget')}
          </div>
        </dl>
      ))}
    </Card>
  );
}

export function PurchaseOrderDetail() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { can, me } = useAuth();
  const toast = useToast();
  const nav = useNavigate();
  const qc = useQueryClient();
  const reason = useReason();
  const lookups = useLookups();
  const projects = useProjects();
  const { data: po, isLoading, error } = useQuery({ queryKey: ['purchase-order', id], queryFn: () => api.get(`/purchase-orders/${id}`) });
  const [receive, setReceive] = useState<Record<string, string> | null>(null);
  const [grn, setGrn] = useState({ receipt_date: today(), delivery_note_ref: '' });
  const [advance, setAdvance] = useState<any>(null);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['purchase-order', id] }); qc.invalidateQueries({ queryKey: ['purchase-orders'] }); };
  const onError = (e: Error) => { toast(e.message, 'error'); refresh(); };
  const patch = useMutation({ mutationFn: (b: any) => api.patch(`/purchase-orders/${id}`, b), onSuccess: refresh, onError });
  const act = (a: string, b?: any) => api.post(`/purchase-orders/${id}/${a}`, b ?? {}).then(refresh, onError);
  const receiveGoods = useMutation({
    mutationFn: () => api.post(`/purchase-orders/${id}/receipts`, { ...grn, delivery_note_ref: grn.delivery_note_ref || undefined,
      lines: Object.entries(receive!).filter(([, q]) => Number(q) > 0).map(([po_line_id, quantity]) => ({ po_line_id, quantity })) }),
    onSuccess: () => { setReceive(null); refresh(); toast(t('fin.goodsReceived')); }, onError,
  });
  const newBill = useMutation({
    mutationFn: (b: any) => api.post('/supplier-invoices', { po_id: id, ...b }),
    onSuccess: (b) => nav(`/supplier-invoices/${b.id}`), onError,
  });
  const payAdvance = useMutation({
    mutationFn: () => api.post('/supplier-payments', { kind: 'advance', po_id: id, ...advance }),
    onSuccess: () => { setAdvance(null); refresh(); toast(t('common.saved')); }, onError,
  });
  const amend = useMutation({ mutationFn: () => api.post(`/purchase-orders/${id}/amend`), onSuccess: (a) => nav(`/purchases/orders/${a.id}`), onError });

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const draft = po.status === 'draft';
  const editable = draft && can('procurement.order');
  const open = ['issued', 'partially_received'].includes(po.status);
  const live = ['issued', 'partially_received', 'received'].includes(po.status);
  const mine = po.submitted_by === me?.id;
  const canDecide = po.status === 'pending_approval' && can('procurement.approve') && (!mine || (!!me?.allow_self_approval && !me?.segregation_of_duties));
  const field = (k: string, type = 'text') => (
    <Input type={type} name={k} disabled={!editable} defaultValue={po[k] ?? ''} key={`${k}-${po.updated_at}`}
      onBlur={(e) => { if ((e.target.value || null) !== (po[k] ?? null)) patch.mutate({ [k]: e.target.value || null }); }} />
  );
  const lineCols = !draft;
  return (
    <div className="space-y-4">
      <PageHeader
        title={<span className="flex flex-wrap items-center gap-2">{t('pur.order')} {po.number && <span className="font-mono">{po.number}</span>}<Status value={po.status} />
          {po.revision_no > 0 && <span className="text-xs text-slate-500">{t('fin.amendmentNo', { n: po.revision_no })}</span>}</span>}
        subtitle={<>{pick(po.supplier_name, po.supplier_name_ar)}{po.request_number && <> · <Link className="link" to={`/purchases/requests/${po.purchase_request_id}`}>{po.request_number}</Link></>}
          {po.project_number && <> · <Link className="link" to={`/projects/${po.project_id}`}>{po.project_number}</Link></>}</>}
        actions={<>
          <Button variant="secondary" onClick={() => api.openFile(`/purchase-orders/${id}/pdf`).catch(onError)}><FileDown className="h-4 w-4" />PDF</Button>
          <Button variant="secondary" data-testid="word" onClick={() => api.openFile(`/purchase-orders/${id}/pdf?format=word`, `${po.number ?? 'PO-draft'}.doc`).catch(onError)}>Word</Button>
          {editable && <Button onClick={() => act('submit')} data-testid="submit-po">{t('pur.submit')}</Button>}
          {po.status === 'pending_approval' && mine && <Button variant="secondary" onClick={() => act('withdraw')}>{t('quote.withdraw')}</Button>}
          {canDecide && <>
            <Button variant="danger" onClick={() => reason.ask(t('quote.reject'), (c) => act('reject', { comment: c }), { danger: true })}>{t('quote.reject')}</Button>
            <Button variant="success" data-testid="approve-po" onClick={() => reason.ask(t('quote.approve'), (c) => act('approve', c ? { comment: c } : {}), { required: !!po.over_budget, label: po.over_budget ? t('fin.overBudgetComment') : undefined })}>{t('quote.approve')}</Button>
          </>}
          {po.status === 'approved' && can('procurement.order') && <Button onClick={() => act('issue')} data-testid="issue-po">{t('pur.issue')}</Button>}
          {open && (can('procurement.request') || can('procurement.order')) && <Button data-testid="receive-po" onClick={() => setReceive(Object.fromEntries(po.lines.map((l: any) => [l.id, String(Math.max(Number(l.quantity) - Number(l.received_qty), 0))])))}>{t('fin.receiveGoods')}</Button>}
          {live && can('procurement.order') && <Button variant="secondary" data-testid="bill-po" onClick={() => reason.ask(t('fin.enterSupplierInvoice'), (no) => newBill.mutate({ supplier_invoice_number: no, invoice_date: today() }), { label: t('fin.supplierInvoiceNo') })}>{t('fin.enterSupplierInvoice')}</Button>}
          {['approved', 'issued', 'partially_received'].includes(po.status) && can('payments.write') && <Button variant="secondary" onClick={() => setAdvance({ payment_date: today(), amount: '', bank_account_code: '1010', reference: '' })}>{t('fin.payAdvance')}</Button>}
          {live && can('procurement.order') && <Button variant="secondary" busy={amend.isPending} onClick={() => amend.mutate()} data-testid="amend-po">{t('fin.amend')}</Button>}
          {live && can('procurement.order') && <Button variant="ghost" onClick={() => act('close')}>{t('pur.close')}</Button>}
          {['draft', 'pending_approval', 'approved', 'issued'].includes(po.status) && can('procurement.order') && <Button variant="ghost" onClick={() => reason.ask(t('common.cancel'), (r) => act('cancel', { reason: r }), { danger: true, label: t('inv.reason') })}>{t('common.cancel')}</Button>}
        </>} />
      {po.status === 'cancelled' && <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-900">{po.cancel_reason}</div>}
      {po.status === 'superseded' && <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm">{t('fin.supersededHint')} {po.versions.filter((v: any) => v.revision_no > po.revision_no).map((v: any) => <Link key={v.id} className="link me-2" to={`/purchases/orders/${v.id}`}>{v.number ?? t('pur.draft')}</Link>)}</div>}
      {po.decision_comment && <div className="rounded-md border bg-slate-50 p-3 text-sm">“{po.decision_comment}”</div>}
      <div className="grid gap-4 lg:grid-cols-3">
        <Card title={t('pur.items')} bodyClass="p-0" className="lg:col-span-2">
          <Items lines={po.lines} editable={editable} price="unit_price" currency={po.currency}
            onAdd={(b) => api.post(`/purchase-orders/${id}/lines`, b).then(refresh, onError)}
            onPatch={(lid, b) => api.patch(`/purchase-order-lines/${lid}`, b).then(refresh, onError)}
            onDelete={(lid) => api.del(`/purchase-order-lines/${lid}`).then(refresh, onError)} />
          {lineCols && (
            <table className="w-full border-t text-xs"><thead className="bg-slate-50"><tr>
              <th className="th">{t('pur.item')}</th><th className="th text-end">{t('fin.ordered')}</th><th className="th text-end">{t('fin.receivedQty')}</th>
              <th className="th text-end">{t('fin.invoicedQty')}</th><th className="th text-end">{t('fin.balance')}</th>
            </tr></thead><tbody className="divide-y">
              {po.lines.map((l: any) => (
                <tr key={l.id} data-testid="po-line-progress"><td className="td">{l.description}</td><td className="td num">{num(l.quantity)}</td><td className="td num">{num(l.received_qty)}</td>
                  <td className="td num">{num(l.invoiced_qty)}</td><td className="td num">{num(Number(l.quantity) - Number(l.received_qty))}</td></tr>
              ))}
            </tbody></table>
          )}
        </Card>
        <div className="space-y-4">
          <Card title={t('inv.totals')}>
            <dl className="space-y-1.5 text-sm">
              <Row label={t('inv.subtotal')}>{money(po.taxable_amount)}</Row>
              <Row label={t('inv.vat')}>{money(po.vat_total)}</Row>
              <Row label={t('common.total')} strong testId="po-total">{money(po.total_amount, po.currency)}</Row>
              {Number(po.advance_open) > 0 && <Row label={t('fin.advanceOpen')}>{money(po.advance_open)}</Row>}
            </dl>
          </Card>
          <BudgetCheck check={po.budget_check} />
          <Approvals info={po.approvals} />
        </div>
      </div>
      <Card title={t('inv.details')}>
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label={t('fin.project')}>
            <Select name="project_id" disabled={!editable} value={po.project_id ?? ''} onChange={(e) => patch.mutate({ project_id: e.target.value || null })}>
              <option value="">—</option>{projects.data?.map((p: any) => <option key={p.id} value={p.id}>{p.number} · {p.name}</option>)}
            </Select>
          </Field>
          <Field label={t('fin.costCategory')}>
            <Select name="cost_category" disabled={!editable} value={po.cost_category ?? 'general'} onChange={(e) => patch.mutate({ cost_category: e.target.value })}>
              {lookups.data?.cost_categories.map((c: any) => <option key={c.code} value={c.code}>{pick(c.name_en, c.name_ar)}</option>)}
            </Select>
          </Field>
          <Field label={t('fin.retentionPct')}>{field('retention_pct', 'number')}</Field>
          <Field label={t('pur.quoteRef')}>{field('supplier_quote_ref')}</Field>
          <Field label={t('pur.deliveryDate')}>{field('delivery_date', 'date')}</Field>
          <Field label={t('pur.paymentTerms')}>{field('payment_terms')}</Field>
          <Field label={t('pur.deliverTo')} className="sm:col-span-3">{field('delivery_address')}</Field>
          <Field label={t('pur.terms')} className="sm:col-span-3"><Textarea disabled={!editable} defaultValue={po.terms ?? ''} key={`terms-${po.updated_at}`}
            onBlur={(e) => e.target.value !== (po.terms ?? '') && patch.mutate({ terms: e.target.value })} /></Field>
        </div>
      </Card>
      <div className="grid gap-4 lg:grid-cols-2">
        <Card title={t('fin.goodsReceipts')} bodyClass="p-0">
          {!po.receipts.length ? <Empty /> : <table className="w-full text-sm"><tbody className="divide-y">
            {po.receipts.map((g: any) => (
              <tr key={g.id} data-testid="grn-row">
                <td className="td font-mono text-xs">{g.number}</td><td className="td">{date(g.receipt_date)}{g.delivery_note_ref && <div className="text-xs text-slate-400">{g.delivery_note_ref}</div>}</td>
                <td className="td text-xs">{g.lines?.map((l: any) => `${num(l.quantity)} ${l.unit} ${l.description}`).join('; ')}</td>
                <td className="td num">{money(g.amount)}</td>
                <td className="td">{g.cancelled_at ? <Status value="cancelled" /> : can('procurement.order') && <button className="link text-xs" onClick={() => reason.ask(t('common.cancel'), (r) => api.post(`/goods-receipts/${g.id}/cancel`, { reason: r }).then(refresh, onError), { danger: true })}>{t('common.cancel')}</button>}</td>
              </tr>
            ))}
          </tbody></table>}
        </Card>
        <Card title={t('fin.supplierInvoices')} bodyClass="p-0">
          {!po.supplier_invoices.length ? <Empty /> : <table className="w-full text-sm"><tbody className="divide-y">
            {po.supplier_invoices.map((b: any) => (
              <tr key={b.id}><td className="td font-mono text-xs"><Link className="link" to={`/supplier-invoices/${b.id}`}>{b.number ?? t('pur.draft')}</Link></td>
                <td className="td">{b.supplier_invoice_number}</td><td className="td"><Status value={b.status} /> {b.match_status && <Status value={b.match_status} />}</td>
                <td className="td num">{money(b.total_amount)}</td><td className="td num text-xs text-slate-500">{t('fin.paid')} {money(b.amount_paid)}</td></tr>
            ))}
          </tbody></table>}
          {po.payments.length > 0 && <div className="border-t px-4 py-2 text-xs text-slate-500">{po.payments.map((p: any) => (
            <div key={p.id}>{p.number} · {t(`fin.payKind.${p.kind}`)} · {date(p.payment_date)} · {money(p.amount)}{p.voided_at && ` (${t('fin.voided')})`}</div>
          ))}</div>}
        </Card>
      </div>
      {po.versions.length > 1 && <Card title={t('fin.versions')} bodyClass="p-0"><table className="w-full text-sm"><tbody className="divide-y">
        {po.versions.map((v: any) => (
          <tr key={v.id} className={v.id === po.id ? 'bg-brand-50/40' : ''}><td className="td font-mono text-xs"><Link className="link" to={`/purchases/orders/${v.id}`}>{v.number ?? t('pur.draft')}</Link></td>
            <td className="td">{v.revision_no === 0 ? t('fin.original') : t('fin.amendmentNo', { n: v.revision_no })}</td><td className="td"><Status value={v.status} /></td><td className="td num">{money(v.total_amount)}</td></tr>
        ))}
      </tbody></table></Card>}
      <Attachments entityType="purchase_order" entityId={po.id} canWrite={can('procurement.order')} />

      <Modal open={!!receive} onClose={() => setReceive(null)} title={t('fin.receiveGoods')} wide
        footer={<Button busy={receiveGoods.isPending} onClick={() => receiveGoods.mutate()} data-testid="grn-confirm">{t('fin.recordReceipt')}</Button>}>
        <ErrorBox error={receiveGoods.error} />
        <div className="mb-3 grid gap-3 sm:grid-cols-2">
          <Field label={t('common.date')}><Input type="date" value={grn.receipt_date} onChange={(e) => setGrn({ ...grn, receipt_date: e.target.value })} /></Field>
          <Field label={t('fin.deliveryNote')}><Input name="delivery_note_ref" value={grn.delivery_note_ref} onChange={(e) => setGrn({ ...grn, delivery_note_ref: e.target.value })} /></Field>
        </div>
        <table className="w-full text-sm"><thead className="bg-slate-50"><tr><th className="th">{t('pur.item')}</th><th className="th text-end">{t('fin.stillToReceive')}</th><th className="th w-32 text-end">{t('fin.receivedNow')}</th></tr></thead>
          <tbody className="divide-y">{receive && po.lines.map((l: any) => (
            <tr key={l.id}><td className="td">{l.description}</td><td className="td num">{num(Number(l.quantity) - Number(l.received_qty))} {l.unit}</td>
              <td className="td"><Input name={`qty_${l.sort_order}`} type="number" step="any" className="text-end" value={receive[l.id]} onChange={(e) => setReceive({ ...receive, [l.id]: e.target.value })} /></td></tr>
          ))}</tbody></table>
      </Modal>
      <Modal open={!!advance} onClose={() => setAdvance(null)} title={t('fin.payAdvance')}
        footer={<Button busy={payAdvance.isPending} onClick={() => payAdvance.mutate()}>{t('common.confirm')}</Button>}>
        <ErrorBox error={payAdvance.error} />
        {advance && <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('common.date')}><Input type="date" value={advance.payment_date} onChange={(e) => setAdvance({ ...advance, payment_date: e.target.value })} /></Field>
          <Field label={t('fin.amount')}><Input type="number" step="any" value={advance.amount} onChange={(e) => setAdvance({ ...advance, amount: e.target.value })} /></Field>
          <Field label={t('fin.paidFrom')}><Select value={advance.bank_account_code} onChange={(e) => setAdvance({ ...advance, bank_account_code: e.target.value })}>
            {lookups.data?.bank_accounts.map((b: any) => <option key={b.code} value={b.code}>{b.code} · {pick(b.name_en, b.name_ar)}</option>)}</Select></Field>
          <Field label={t('fin.reference')}><Input value={advance.reference} onChange={(e) => setAdvance({ ...advance, reference: e.target.value })} /></Field>
        </div>}
      </Modal>
      {reason.modal}
    </div>
  );
}

export function PurchaseRequestDetail() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { can, me } = useAuth();
  const toast = useToast();
  const nav = useNavigate();
  const qc = useQueryClient();
  const reason = useReason();
  const lookups = useLookups();
  const projects = useProjects();
  const { data: pr, isLoading, error } = useQuery({ queryKey: ['purchase-request', id], queryFn: () => api.get(`/purchase-requests/${id}`) });
  const [order, setOrder] = useState<{ id: string; name: string } | null>(null);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['purchase-request', id] }); qc.invalidateQueries({ queryKey: ['purchase-requests'] }); qc.invalidateQueries({ queryKey: ['quotes', id] }); };
  const onError = (e: Error) => { toast(e.message, 'error'); refresh(); };
  const act = useMutation({ mutationFn: ({ a, b }: { a: string; b?: any }) => api.post(`/purchase-requests/${id}/${a}`, b ?? {}), onSuccess: refresh, onError });
  const patch = (b: any) => api.patch(`/purchase-requests/${id}`, b).then(refresh, onError);
  const makeOrder = useMutation({
    mutationFn: async () => api.post(`/purchase-requests/${id}/order`, { supplier_id: await supplierId(order!, t) }),
    onSuccess: (po) => nav(`/purchases/orders/${po.id}`),
  });

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const mine = pr.requested_by === me?.id;
  const editable = pr.status === 'draft' && mine;
  const selfOk = !!me?.allow_self_approval && !me?.segregation_of_duties;
  const canDecide = pr.status === 'submitted' && can('procurement.approve') && (!mine || selfOk);
  const quickApprove = editable && can('procurement.approve') && selfOk;
  const approveNow = async () => {
    try { await api.post(`/purchase-requests/${id}/submit`); await act.mutateAsync({ a: 'approve' }); } catch (e) { onError(e as Error); }
  };
  const text = (k: string, area = false) => area
    ? <Textarea name={k} disabled={!editable} defaultValue={pr[k] ?? ''} key={`${k}-${pr.updated_at}`} onBlur={(e) => e.target.value !== (pr[k] ?? '') && patch({ [k]: e.target.value })} />
    : <Input name={k} type={k === 'needed_by' ? 'date' : 'text'} disabled={!editable} defaultValue={pr[k] ?? ''} key={`${k}-${pr.updated_at}`} onBlur={(e) => (e.target.value || null) !== (pr[k] ?? null) && patch({ [k]: e.target.value || null })} />;
  return (
    <div className="space-y-4">
      <PageHeader
        title={<span className="flex items-center gap-2">{pr.title}<Badge tone={TONES[pr.status]}>{t(`pur.status.${pr.status}`)}</Badge></span>}
        subtitle={<><span className="font-mono">{pr.number}</span> · {pr.requested_by_name}{pr.decided_by_name && <> · {t('pur.decidedBy')} {pr.decided_by_name}</>}
          {pr.project_number && <> · <Link className="link" to={`/projects/${pr.project_id}`}>{pr.project_number}</Link></>}</>}
        actions={<>
          {quickApprove && <Button variant="success" busy={act.isPending} onClick={approveNow} data-testid="approve-pr">{t('quote.approve')}</Button>}
          {editable && <Button variant={quickApprove ? 'secondary' : undefined} onClick={() => act.mutate({ a: 'submit' })} data-testid="submit-pr">{t('pur.submit')}</Button>}
          {pr.status === 'submitted' && mine && <Button variant="secondary" onClick={() => act.mutate({ a: 'withdraw' })}>{t('quote.withdraw')}</Button>}
          {canDecide && <><Button variant="danger" onClick={() => reason.ask(t('quote.reject'), (c) => act.mutate({ a: 'reject', b: { comment: c } }), { danger: true })}>{t('quote.reject')}</Button>
            <Button variant="success" data-testid="approve-pr" onClick={() => act.mutate({ a: 'approve' })}>{t('quote.approve')}</Button></>}
          {pr.status === 'approved' && can('procurement.order') && <Button variant="secondary" onClick={() => setOrder({ id: '', name: '' })} data-testid="order-pr">{t('fin.orderWithoutQuotes')}</Button>}
          {['draft', 'submitted', 'approved'].includes(pr.status) && (mine || can('procurement.approve')) && <Button variant="ghost" onClick={() => act.mutate({ a: 'cancel' })}>{t('common.cancel')}</Button>}
        </>} />
      {pr.decision_comment && <div className="rounded-md border bg-slate-50 p-3 text-sm">“{pr.decision_comment}”</div>}
      {pr.orders?.length > 0 && <div className="text-sm">{t('pur.orders')}: {pr.orders.map((o: any) => <Link key={o.id} className="link me-2" to={`/purchases/orders/${o.id}`}>{o.number ?? t('pur.draft')}</Link>)}</div>}
      <div className="grid gap-4 lg:grid-cols-3">
        <Card title={t('pur.items')} bodyClass="p-0" className="lg:col-span-2">
          <Items lines={pr.lines} editable={editable} price="estimated_unit_cost" currency="SAR"
            onAdd={(b) => api.post(`/purchase-requests/${id}/lines`, b).then(refresh, onError)}
            onPatch={(lid, b) => api.patch(`/purchase-request-lines/${lid}`, b).then(refresh, onError)}
            onDelete={(lid) => api.del(`/purchase-request-lines/${lid}`).then(refresh, onError)} />
          <div className="border-t px-4 py-2 text-end text-sm font-semibold">{t('pur.estTotal')}: {money(pr.estimated_total, 'SAR')}</div>
        </Card>
        <div className="space-y-4"><BudgetCheck check={pr.budget_check} /><Approvals info={pr.approvals} /></div>
      </div>
      <Card title={t('inv.details')}>
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label={t('fin.project')}><Select name="project_id" disabled={!editable} value={pr.project_id ?? ''} onChange={(e) => patch({ project_id: e.target.value || null })}>
            <option value="">—</option>{projects.data?.map((p: any) => <option key={p.id} value={p.id}>{p.number} · {p.name}</option>)}</Select></Field>
          <Field label={t('fin.costCategory')}><Select name="cost_category" disabled={!editable} value={pr.cost_category ?? 'general'} onChange={(e) => patch({ cost_category: e.target.value })}>
            {lookups.data?.cost_categories.map((c: any) => <option key={c.code} value={c.code}>{pick(c.name_en, c.name_ar)}</option>)}</Select></Field>
          <Field label={t('fin.neededBy')}>{text('needed_by')}</Field>
          <Field label={t('fin.technicalSpec')} className="sm:col-span-3">{text('technical_spec', true)}</Field>
          <Field label={t('fin.justification')} className="sm:col-span-3">{text('justification', true)}</Field>
        </div>
      </Card>
      {['approved', 'ordered'].includes(pr.status) && <Quotes pr={pr} onError={onError} refresh={refresh} />}
      <Attachments entityType="purchase_request" entityId={pr.id} canWrite={can('procurement.request')} />
      <Modal open={!!order} onClose={() => setOrder(null)} title={t('pur.makeOrder')}
        footer={<Button busy={makeOrder.isPending} onClick={() => makeOrder.mutate()}>{t('common.create')}</Button>}>
        <ErrorBox error={makeOrder.error} />
        {order && <Field label={t('pur.supplier')}><SupplierPicker value={order} onChange={setOrder} /></Field>}
      </Modal>
      {reason.modal}
    </div>
  );
}

/** Supplier quotations for a request, side by side; selecting one creates the purchase order. */
function Quotes({ pr, onError, refresh }: { pr: any; onError: (e: Error) => void; refresh: () => void }) {
  const { t } = useTranslation();
  const { can } = useAuth();
  const nav = useNavigate();
  const reason = useReason();
  const { data, isLoading } = useQuery({ queryKey: ['quotes', pr.id], queryFn: () => api.get(`/purchase-requests/${pr.id}/quotes`) });
  const blank = { supplier: { id: '', name: '' }, quote_ref: '', delivery_days: '', payment_terms: '', warranty: '', technical_compliance: 'compliant', commercial_notes: '', prices: {} as Record<string, string> };
  const [f, setF] = useState<any>(null);
  const add = useMutation({
    mutationFn: async () => api.post(`/purchase-requests/${pr.id}/quotes`, {
      supplier_id: await supplierId(f.supplier, t), quote_ref: f.quote_ref || undefined, delivery_days: f.delivery_days || null,
      payment_terms: f.payment_terms || undefined, warranty: f.warranty || undefined, technical_compliance: f.technical_compliance,
      commercial_notes: f.commercial_notes || undefined,
      lines: Object.entries(f.prices).filter(([, v]) => v !== '').map(([request_line_id, unit_price]) => ({ request_line_id, unit_price })),
    }),
    onSuccess: () => { setF(null); refresh(); },
  });
  const select = (q: any) => {
    const run = (r: string) => api.post(`/supplier-quotes/${q.id}/select`, r ? { reason: r } : {}).then((x) => nav(`/purchases/orders/${x.purchase_order_id}`), onError);
    if (q.lowest_total) return reason.ask(t('fin.selectQuote'), run, { required: false });
    reason.ask(t('fin.selectQuote'), run, { label: t('fin.whyNotLowest') });
  };
  const quotes: any[] = data?.quotes ?? [];
  const selected = quotes.find((q) => q.status === 'selected');
  return (
    <Card title={t('fin.supplierQuotes')} bodyClass="p-0" actions={!selected && can('procurement.order') && <Button variant="secondary" onClick={() => setF(blank)} data-testid="add-quote"><Plus className="h-4 w-4" />{t('fin.addQuote')}</Button>}>
      {isLoading ? <Spinner /> : !quotes.length ? <Empty>{t('fin.noQuotes')}</Empty> : (
        <div className="overflow-x-auto"><table className="w-full text-sm" data-testid="quote-comparison"><thead className="bg-slate-50"><tr>
          <th className="th">{t('pur.item')}</th>
          {quotes.map((q) => <th key={q.id} className="th text-end">{pick(q.supplier_name, q.supplier_name_ar)}<div className="font-normal text-slate-400">{q.number}</div></th>)}
        </tr></thead><tbody className="divide-y">
          {data.comparison.map((it: any) => (
            <tr key={it.id}><td className="td">{it.description}<div className="text-xs text-slate-400">{num(it.quantity)} {it.unit}</div></td>
              {it.prices.map((p: any) => <td key={p.quote_id} className={cx('td num', it.lowest_quote_id === p.quote_id && 'font-semibold text-emerald-700')}>{p.unit_price ? money(p.unit_price) : '—'}</td>)}</tr>
          ))}
          {([['fin.subtotal', 'subtotal'], ['inv.vat', 'vat_total'], ['common.total', 'total_amount']] as const).map(([label, k]) => (
            <tr key={k} className={k === 'total_amount' ? 'font-semibold' : ''}><td className="td">{t(label)}</td>
              {quotes.map((q) => <td key={q.id} className={cx('td num', k === 'total_amount' && q.lowest_total && 'text-emerald-700')}>{money(q[k])}</td>)}</tr>
          ))}
          {([['fin.delivery', (q: any) => q.delivery_days != null ? `${q.delivery_days} ${t('fin.days')}${q.fastest_delivery ? ' ★' : ''}` : '—'],
             ['pur.paymentTerms', (q: any) => q.payment_terms ?? '—'], ['fin.warranty', (q: any) => q.warranty ?? '—'],
             ['fin.compliance', (q: any) => t(`fin.compliant.${q.technical_compliance}`)], ['common.notes', (q: any) => q.commercial_notes ?? '']] as const).map(([label, f]) => (
            <tr key={label}><td className="td text-slate-500">{t(label)}</td>{quotes.map((q) => <td key={q.id} className={cx('td text-end text-xs', q.technical_compliance === 'non_compliant' && label === 'fin.compliance' && 'text-red-700')}>{f(q)}</td>)}</tr>
          ))}
          <tr><td className="td" />{quotes.map((q) => (
            <td key={q.id} className="td text-end">
              {q.status === 'selected' ? <Badge tone="green">{t('fin.selected')}</Badge> : q.status === 'not_selected' ? <span className="text-xs text-slate-400">{t('fin.notSelected')}</span>
                : !selected && can('procurement.order') && <Button variant={q.lowest_total ? 'success' : 'secondary'} onClick={() => select(q)} data-testid={`select-${q.number}`}>{t('fin.select')}</Button>}
              {q.lowest_total && <div className="mt-1 text-xs text-emerald-700">{t('fin.lowestCompliant')}</div>}
            </td>
          ))}</tr>
        </tbody></table></div>
      )}
      {selected?.selection_reason && <div className="border-t px-4 py-2 text-xs text-slate-500">{t('fin.selectionReason')}: “{selected.selection_reason}”</div>}
      <Modal open={!!f} onClose={() => setF(null)} title={t('fin.addQuote')} wide
        footer={<Button busy={add.isPending} onClick={() => add.mutate()} data-testid="save-quote">{t('common.save')}</Button>}>
        <ErrorBox error={add.error} />
        {f && <>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label={t('pur.supplier')}><SupplierPicker value={f.supplier} onChange={(v) => setF({ ...f, supplier: v })} /></Field>
            <Field label={t('pur.quoteRef')}><Input name="quote_ref" value={f.quote_ref} onChange={(e) => setF({ ...f, quote_ref: e.target.value })} /></Field>
            <Field label={t('fin.deliveryDays')}><Input name="delivery_days" type="number" value={f.delivery_days} onChange={(e) => setF({ ...f, delivery_days: e.target.value })} /></Field>
            <Field label={t('pur.paymentTerms')}><Input name="payment_terms" value={f.payment_terms} onChange={(e) => setF({ ...f, payment_terms: e.target.value })} /></Field>
            <Field label={t('fin.warranty')}><Input name="warranty" value={f.warranty} onChange={(e) => setF({ ...f, warranty: e.target.value })} /></Field>
            <Field label={t('fin.compliance')}><Select name="technical_compliance" value={f.technical_compliance} onChange={(e) => setF({ ...f, technical_compliance: e.target.value })}>
              {['compliant', 'partial', 'non_compliant'].map((c) => <option key={c} value={c}>{t(`fin.compliant.${c}`)}</option>)}</Select></Field>
            <Field label={t('common.notes')} className="sm:col-span-2"><Input name="commercial_notes" value={f.commercial_notes} onChange={(e) => setF({ ...f, commercial_notes: e.target.value })} /></Field>
          </div>
          <table className="mt-3 w-full text-sm"><thead className="bg-slate-50"><tr><th className="th">{t('pur.item')}</th><th className="th text-end">{t('quote.qty')}</th><th className="th w-36 text-end">{t('pur.unitPrice')} ({t('fin.exVat')})</th></tr></thead>
            <tbody className="divide-y">{pr.lines.map((l: any, i: number) => (
              <tr key={l.id}><td className="td">{l.description}</td><td className="td num">{num(l.quantity)} {l.unit}</td>
                <td className="td"><Input name={`price_${i}`} type="number" step="any" className="text-end" value={f.prices[l.id] ?? ''} onChange={(e) => setF({ ...f, prices: { ...f.prices, [l.id]: e.target.value } })} /></td></tr>
            ))}</tbody></table>
        </>}
      </Modal>
      {reason.modal}
    </Card>
  );
}
