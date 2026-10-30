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

const TONES: Record<string, Tone> = {
  draft: 'slate', submitted: 'amber', approved: 'green', rejected: 'red', ordered: 'blue', cancelled: 'red',
  issued: 'green', received: 'blue', closed: 'slate',
};

// Pick an existing supplier or type a new name; a new supplier is created when the order is.
function SupplierPicker({ value, onChange }: { value: { id: string; name: string }; onChange: (v: { id: string; name: string }) => void }) {
  const { t } = useTranslation();
  const { data = [] } = useQuery({ queryKey: ['suppliers', 'select'], queryFn: () => api.get('/suppliers?limit=500') });
  return (
    <div className="grid gap-2">
      <Select name="supplier_id" value={value.id} onChange={(e) => onChange({ id: e.target.value, name: '' })}>
        <option value="">{t('pur.newSupplier')}</option>
        {data.map((s: any) => <option key={s.id} value={s.id}>{pick(s.name_en, s.name_ar)}</option>)}
      </Select>
      {!value.id && <Input name="supplier_name" placeholder={t('pur.supplierName')} value={value.name} onChange={(e) => onChange({ id: '', name: e.target.value })} />}
    </div>
  );
}

const supplierId = async (v: { id: string; name: string }, t: (k: string) => string) => {
  if (v.id) return v.id;
  if (!v.name.trim()) throw new Error(t('pur.pickSupplier'));
  return (await api.post('/suppliers', { name_en: v.name.trim() })).id as string;
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

export function PurchaseOrderDetail() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const { data: po, isLoading, error } = useQuery({ queryKey: ['purchase-order', id], queryFn: () => api.get(`/purchase-orders/${id}`) });
  const [cancel, setCancel] = useState<string | null>(null);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['purchase-order', id] }); qc.invalidateQueries({ queryKey: ['purchase-orders'] }); };
  const onError = (e: Error) => { toast(e.message, 'error'); refresh(); };
  const patch = useMutation({ mutationFn: (b: any) => api.patch(`/purchase-orders/${id}`, b), onSuccess: refresh, onError });
  const act = useMutation({ mutationFn: ({ a, b }: { a: string; b?: any }) => api.post(`/purchase-orders/${id}/${a}`, b ?? {}), onSuccess: () => { setCancel(null); refresh(); }, onError });

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const draft = po.status === 'draft';
  const editable = draft && can('procurement.order');
  const field = (k: string, type = 'text') => (
    <Input type={type} disabled={!editable} defaultValue={po[k] ?? ''} key={`${k}-${po.updated_at}`}
      onBlur={(e) => { if ((e.target.value || null) !== (po[k] ?? null)) patch.mutate({ [k]: e.target.value }); }} />
  );
  return (
    <div className="space-y-4">
      <PageHeader
        title={<span className="flex items-center gap-2">{t('pur.order')} {po.number && <span className="font-mono">{po.number}</span>}<Badge tone={TONES[po.status]}>{t(`pur.status.${po.status}`)}</Badge></span>}
        subtitle={<>{pick(po.supplier_name, po.supplier_name_ar)}{po.request_number && <> · <Link className="link" to={`/purchases/requests/${po.purchase_request_id}`}>{po.request_number}</Link></>}</>}
        actions={<>
          <Button variant="secondary" onClick={() => api.openFile(`/purchase-orders/${id}/pdf`).catch(onError)}><FileDown className="h-4 w-4" />PDF</Button>
          <Button variant="secondary" data-testid="word" onClick={() => api.openFile(`/purchase-orders/${id}/pdf?format=word`, `${po.number ?? 'PO-draft'}.doc`).catch(onError)}>Word</Button>
          {editable && <Button busy={act.isPending} onClick={() => act.mutate({ a: 'issue' })} data-testid="issue-po">{t('pur.issue')}</Button>}
          {po.status === 'issued' && can('procurement.order') && <Button onClick={() => act.mutate({ a: 'receive' })}>{t('pur.receive')}</Button>}
          {po.status === 'received' && can('procurement.order') && <Button variant="secondary" onClick={() => act.mutate({ a: 'close' })}>{t('pur.close')}</Button>}
          {['draft', 'issued'].includes(po.status) && can('procurement.order') && <Button variant="ghost" onClick={() => setCancel('')}>{t('common.cancel')}</Button>}
        </>} />
      {po.status === 'cancelled' && <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-900">{po.cancel_reason}</div>}
      <div className="grid gap-4 lg:grid-cols-3">
        <Card title={t('pur.items')} bodyClass="p-0" className="lg:col-span-2">
          <Items lines={po.lines} editable={editable} price="unit_price" currency={po.currency}
            onAdd={(b) => api.post(`/purchase-orders/${id}/lines`, b).then(refresh, onError)}
            onPatch={(lid, b) => api.patch(`/purchase-order-lines/${lid}`, b).then(refresh, onError)}
            onDelete={(lid) => api.del(`/purchase-order-lines/${lid}`).then(refresh, onError)} />
        </Card>
        <Card title={t('inv.totals')}>
          <dl className="space-y-1.5 text-sm">
            <div className="flex justify-between"><dt className="text-slate-500">{t('inv.subtotal')}</dt><dd className="num">{money(po.subtotal)}</dd></div>
            <div className="flex justify-between"><dt className="text-slate-500">{t('inv.vat')}</dt><dd className="num">{money(po.vat_total)}</dd></div>
            <div className="flex justify-between border-t pt-1.5 font-semibold"><dt>{t('common.total')}</dt><dd className="num" data-testid="po-total">{money(po.total_amount, po.currency)}</dd></div>
          </dl>
        </Card>
      </div>
      <Card title={t('inv.details')}>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('pur.quoteRef')}>{field('supplier_quote_ref')}</Field>
          <Field label={t('pur.deliveryDate')}>{field('delivery_date', 'date')}</Field>
          <Field label={t('pur.paymentTerms')}>{field('payment_terms')}</Field>
          <Field label={t('pur.deliverTo')}>{field('delivery_address')}</Field>
          <Field label={t('pur.terms')} className="sm:col-span-2"><Textarea disabled={!editable} defaultValue={po.terms ?? ''} key={`terms-${po.updated_at}`}
            onBlur={(e) => e.target.value !== (po.terms ?? '') && patch.mutate({ terms: e.target.value })} /></Field>
        </div>
      </Card>
      <Modal open={cancel !== null} onClose={() => setCancel(null)} title={t('common.cancel')}
        footer={<Button variant="danger" busy={act.isPending} onClick={() => act.mutate({ a: 'cancel', b: { reason: cancel } })}>{t('common.confirm')}</Button>}>
        <Field label={t('inv.reason')}><Textarea value={cancel ?? ''} onChange={(e) => setCancel(e.target.value)} /></Field>
      </Modal>
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
  const { data: pr, isLoading, error } = useQuery({ queryKey: ['purchase-request', id], queryFn: () => api.get(`/purchase-requests/${id}`) });
  const [reject, setReject] = useState<string | null>(null);
  const [order, setOrder] = useState<{ id: string; name: string } | null>(null);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['purchase-request', id] }); qc.invalidateQueries({ queryKey: ['purchase-requests'] }); };
  const onError = (e: Error) => { toast(e.message, 'error'); refresh(); };
  const act = useMutation({ mutationFn: ({ a, b }: { a: string; b?: any }) => api.post(`/purchase-requests/${id}/${a}`, b ?? {}), onSuccess: () => { setReject(null); refresh(); }, onError });
  const makeOrder = useMutation({
    mutationFn: async () => api.post(`/purchase-requests/${id}/order`, { supplier_id: await supplierId(order!, t) }),
    onSuccess: (po) => nav(`/purchases/orders/${po.id}`),
  });

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const mine = pr.requested_by === me?.id;
  const editable = pr.status === 'draft' && mine;
  const canDecide = pr.status === 'submitted' && can('procurement.approve') && (!mine || !!me?.allow_self_approval);
  // With self-approval allowed, the requester sends and approves a draft in one click.
  const quickApprove = editable && can('procurement.approve') && !!me?.allow_self_approval;
  const approveNow = async () => {
    try { await api.post(`/purchase-requests/${id}/submit`); await act.mutateAsync({ a: 'approve' }); } catch (e) { onError(e as Error); }
  };
  return (
    <div className="space-y-4">
      <PageHeader
        title={<span className="flex items-center gap-2">{pr.title}<Badge tone={TONES[pr.status]}>{t(`pur.status.${pr.status}`)}</Badge></span>}
        subtitle={<><span className="font-mono">{pr.number}</span> · {pr.requested_by_name}{pr.decided_by_name && <> · {t('pur.decidedBy')} {pr.decided_by_name}</>}</>}
        actions={<>
          {quickApprove && <Button variant="success" busy={act.isPending} onClick={approveNow} data-testid="approve-pr">{t('quote.approve')}</Button>}
          {editable && <Button variant={quickApprove ? 'secondary' : undefined} onClick={() => act.mutate({ a: 'submit' })}>{t('pur.submit')}</Button>}
          {pr.status === 'submitted' && mine && <Button variant="secondary" onClick={() => act.mutate({ a: 'withdraw' })}>{t('quote.withdraw')}</Button>}
          {canDecide && <><Button variant="danger" onClick={() => setReject('')}>{t('quote.reject')}</Button><Button variant="success" onClick={() => act.mutate({ a: 'approve' })}>{t('quote.approve')}</Button></>}
          {pr.status === 'approved' && can('procurement.order') && <Button onClick={() => setOrder({ id: '', name: '' })} data-testid="order-pr">{t('pur.makeOrder')}</Button>}
          {['draft', 'submitted', 'approved'].includes(pr.status) && (mine || can('procurement.approve')) && <Button variant="ghost" onClick={() => act.mutate({ a: 'cancel' })}>{t('common.cancel')}</Button>}
        </>} />
      {pr.decision_comment && <div className="rounded-md border bg-slate-50 p-3 text-sm">“{pr.decision_comment}”</div>}
      {pr.orders?.length > 0 && <div className="text-sm">{t('pur.orders')}: {pr.orders.map((o: any) => <Link key={o.id} className="link me-2" to={`/purchases/orders/${o.id}`}>{o.number ?? t('pur.draft')}</Link>)}</div>}
      <Card title={t('pur.items')} bodyClass="p-0">
        <Items lines={pr.lines} editable={editable} price="estimated_unit_cost" currency="SAR"
          onAdd={(b) => api.post(`/purchase-requests/${id}/lines`, b).then(refresh, onError)}
          onPatch={(lid, b) => api.patch(`/purchase-request-lines/${lid}`, b).then(refresh, onError)}
          onDelete={(lid) => api.del(`/purchase-request-lines/${lid}`).then(refresh, onError)} />
        <div className="border-t px-4 py-2 text-end text-sm font-semibold">{t('pur.estTotal')}: {money(pr.estimated_total, 'SAR')}</div>
      </Card>
      <Modal open={reject !== null} onClose={() => setReject(null)} title={t('quote.reject')}
        footer={<Button variant="danger" busy={act.isPending} onClick={() => act.mutate({ a: 'reject', b: { comment: reject } })}>{t('quote.reject')}</Button>}>
        <Field label={t('pur.comment')}><Textarea value={reject ?? ''} onChange={(e) => setReject(e.target.value)} /></Field>
      </Modal>
      <Modal open={!!order} onClose={() => setOrder(null)} title={t('pur.makeOrder')}
        footer={<Button busy={makeOrder.isPending} onClick={() => makeOrder.mutate()}>{t('common.create')}</Button>}>
        <ErrorBox error={makeOrder.error} />
        {order && <Field label={t('pur.supplier')}><SupplierPicker value={order} onChange={setOrder} /></Field>}
      </Modal>
    </div>
  );
}
