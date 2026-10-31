// Purchase Order Center: one place for orders received from customers and orders placed with suppliers.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { date, money, pick } from '../lib/format';
import { Button, Card, Empty, ErrorBox, Input, PageHeader, Select, Spinner } from '../components/ui';
import { Stat, Status } from '../components/fin';

export default function PoCenter() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const summary = useQuery({ queryKey: ['po-center'], queryFn: () => api.get('/po-center/summary') });
  const [f, setF] = useState({ q: '', direction: 'all', status: '', customer_id: '', supplier_id: '', project_id: '', from: '', to: '', min_amount: '', max_amount: '' });
  const orders = useQuery({ queryKey: ['po-center-orders', f], queryFn: () => api.get(`/po-center/orders${qs({ ...f, limit: 200 })}`) });
  const customers = useQuery({ queryKey: ['customers', 'select'], queryFn: () => api.get('/customers?limit=500'), enabled: can('customers.read') });
  const suppliers = useQuery({ queryKey: ['suppliers', 'select'], queryFn: () => api.get('/suppliers?limit=500'), enabled: can('suppliers.read') });
  const projects = useQuery({ queryKey: ['projects'], queryFn: () => api.get('/projects') });
  const set = (k: string) => (e: any) => setF({ ...f, [k]: e.target.value });
  const d = summary.data;
  const link = (o: any) => (o.direction === 'incoming' ? `/customer-pos/${o.id}` : `/purchases/orders/${o.id}`);
  return (
    <div className="space-y-4">
      <PageHeader title={t('fin.poCenter')} subtitle={t('fin.poCenterHint')} actions={<>
        {can('customer_pos.write') && <Link to="/customer-pos"><Button variant="secondary">{t('fin.customerPos')}</Button></Link>}
        {can('procurement.read') && <Link to="/purchases"><Button variant="secondary">{t('pur.orders')}</Button></Link>}
        {can('procurement.read') && <Link to="/supplier-invoices"><Button variant="secondary">{t('fin.supplierInvoices')}</Button></Link>}
      </>} />
      {summary.isLoading ? <Spinner /> : summary.error ? <ErrorBox error={summary.error} /> : (
        <>
          <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-5" data-testid="po-center-stats">
            <Stat label={t('fin.d.incoming')} value={d.incoming_awaiting_review.count} sub={money(d.incoming_awaiting_review.value)} />
            <Stat label={t('fin.d.accepted')} value={money(d.accepted_customer_po_value.value)} sub={t('fin.d.orders', { count: d.accepted_customer_po_value.count })} />
            <Stat label={t('fin.d.awaitingApproval')} value={d.supplier_awaiting_approval.count} sub={money(d.supplier_awaiting_approval.value)} tone={d.supplier_awaiting_approval.count ? 'amber' : undefined} />
            <Stat label={t('fin.d.commitments')} value={money(d.supplier_commitments.open)} sub={t('fin.d.ordered', { value: money(d.supplier_commitments.ordered) })} />
            <Stat label={t('fin.d.deliveries')} value={d.outstanding_deliveries.count} sub={`${money(d.outstanding_deliveries.value)} · ${t('fin.d.overdue', { count: d.outstanding_deliveries.overdue })}`} tone={d.outstanding_deliveries.overdue ? 'red' : undefined} />
            <Stat label={t('fin.d.matching')} value={d.supplier_invoices_pending.count} sub={money(d.supplier_invoices_pending.value)} />
            <Stat label={t('fin.d.paymentsDue')} value={money(d.supplier_payments_due.value)} sub={`${t('fin.d.due7', { value: money(d.supplier_payments_due.due_7_days) })} · ${t('fin.d.overdue', { count: d.supplier_payments_due.overdue })}`} tone={d.supplier_payments_due.overdue ? 'red' : undefined} />
            <Stat label={t('fin.d.overBudget')} value={d.over_budget.count} sub={money(d.over_budget.value)} tone={d.over_budget.count ? 'red' : undefined} />
            <Stat label={t('fin.d.changed')} value={`${d.cancelled_and_amended.amended + d.cancelled_and_amended.customer_amended} / ${d.cancelled_and_amended.cancelled + d.cancelled_and_amended.customer_cancelled}`} sub={t('fin.d.changedSub')} />
          </div>
          <div className="grid gap-4 lg:grid-cols-3">
            <Queue title={t('fin.d.incoming')} items={d.incoming_awaiting_review.items} row={(o) => [<Link key="n" className="link font-mono text-xs" to={`/customer-pos/${o.id}`}>{o.number}</Link>, `${o.customer_name} · ${o.customer_po_number}`, money(o.amount)]} />
            <Queue title={t('fin.d.awaitingApproval')} items={d.supplier_awaiting_approval.items} row={(o) => [<Link key="n" className="link text-xs" to={`/purchases/orders/${o.id}`}>{o.project_number ?? t('pur.draft')}</Link>, `${o.supplier_name}${o.over_budget ? ' ⚠' : ''}`, money(o.taxable_amount)]} />
            <Queue title={t('fin.d.deliveries')} items={d.outstanding_deliveries.items} row={(o) => [<Link key="n" className="link font-mono text-xs" to={`/purchases/orders/${o.id}`}>{o.number}</Link>, o.supplier_name, date(o.delivery_date)]} />
            <Queue title={t('fin.d.matching')} items={d.supplier_invoices_pending.items} row={(b) => [<Link key="n" className="link font-mono text-xs" to={`/supplier-invoices/${b.id}`}>{b.number}</Link>, `${b.supplier_name} · ${b.supplier_invoice_number}`, money(b.total_amount)]} />
            <Queue title={t('fin.d.paymentsDue')} items={d.supplier_payments_due.items} row={(b) => [<Link key="n" className="link font-mono text-xs" to={`/supplier-invoices/${b.id}`}>{b.number}</Link>, `${b.supplier_name} · ${date(b.due_date)}`, money(b.open)]} />
            <Queue title={t('fin.d.overBudget')} items={d.over_budget.items} row={(o) => [<Link key="n" className="link font-mono text-xs" to={`/purchases/orders/${o.id}`}>{o.number ?? t('pur.draft')}</Link>, `${o.supplier_name} · ${o.project_number ?? ''}`, money(o.taxable_amount)]} />
          </div>
        </>
      )}
      <Card title={t('fin.allOrders')} bodyClass="p-0">
        <div className="grid gap-2 border-b p-3 sm:grid-cols-3 lg:grid-cols-6">
          <Input placeholder={t('fin.searchOrders')} value={f.q} onChange={set('q')} name="po_search" className="lg:col-span-2" />
          <Select value={f.direction} onChange={set('direction')} name="direction">{['all', 'incoming', 'outgoing'].map((x) => <option key={x} value={x}>{t(`fin.dir.${x}`)}</option>)}</Select>
          <Input placeholder={t('common.status')} value={f.status} onChange={set('status')} />
          <Select value={f.customer_id} onChange={set('customer_id')}><option value="">{t('common.customer')}</option>{customers.data?.map((c: any) => <option key={c.id} value={c.id}>{pick(c.name_en, c.name_ar)}</option>)}</Select>
          <Select value={f.supplier_id} onChange={set('supplier_id')}><option value="">{t('pur.supplier')}</option>{suppliers.data?.map((s: any) => <option key={s.id} value={s.id}>{pick(s.name_en, s.name_ar)}</option>)}</Select>
          <Select value={f.project_id} onChange={set('project_id')}><option value="">{t('fin.project')}</option>{projects.data?.map((p: any) => <option key={p.id} value={p.id}>{p.number}</option>)}</Select>
          <Input type="date" value={f.from} onChange={set('from')} aria-label={t('fin.from')} />
          <Input type="date" value={f.to} onChange={set('to')} aria-label={t('fin.to')} />
          <Input type="number" placeholder={t('fin.minAmount')} value={f.min_amount} onChange={set('min_amount')} />
          <Input type="number" placeholder={t('fin.maxAmount')} value={f.max_amount} onChange={set('max_amount')} />
        </div>
        {orders.isLoading ? <Spinner /> : orders.error ? <ErrorBox error={orders.error} /> : !orders.data.length ? <Empty /> : (
          <div className="overflow-x-auto"><table className="w-full text-sm" data-testid="po-center-orders"><thead className="bg-slate-50"><tr>
            <th className="th">{t('fin.direction')}</th><th className="th">{t('common.number')}</th><th className="th">{t('fin.theirRef')}</th><th className="th">{t('fin.party')}</th>
            <th className="th">{t('fin.project')}</th><th className="th">{t('common.status')}</th><th className="th">{t('common.date')}</th><th className="th text-end">{t('fin.amountExVat')}</th>
          </tr></thead><tbody className="divide-y">
            {orders.data.map((o: any) => (
              <tr key={`${o.direction}-${o.id}`}>
                <td className="td text-xs">{t(`fin.dir.${o.direction}`)}</td>
                <td className="td font-mono text-xs"><Link className="link" to={link(o)}>{o.number}</Link></td>
                <td className="td">{o.party_reference}</td><td className="td">{o.party_name}</td><td className="td">{o.project_number}</td>
                <td className="td"><Status value={o.status} /></td><td className="td">{date(o.order_date)}</td><td className="td num">{money(o.amount)}</td>
              </tr>
            ))}
          </tbody></table></div>
        )}
      </Card>
    </div>
  );
}

function Queue({ title, items, row }: { title: string; items: any[]; row: (x: any) => React.ReactNode[] }) {
  return (
    <Card title={title} bodyClass="p-0">
      {!items.length ? <Empty /> : <table className="w-full text-sm"><tbody className="divide-y">
        {items.map((x) => <tr key={x.id}>{row(x).map((c, i) => <td key={i} className={i === 2 ? 'td num' : 'td'}>{c}</td>)}</tr>)}
      </tbody></table>}
    </Card>
  );
}
