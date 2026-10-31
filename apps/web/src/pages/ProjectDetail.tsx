// A project's financial position: customer orders, contract value, budget, commitments, actual cost, forecast and profit.
import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Plus } from 'lucide-react';
import { api } from '../lib/api';
import { useAuth } from '../lib/auth';
import { date, money, pick } from '../lib/format';
import { Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Select, Spinner, Textarea, cx, useToast } from '../components/ui';
import { Approvals, Row, Stat, Status, catName, useLookups, useReason } from '../components/fin';
import Attachments from '../components/Attachments';

export default function ProjectDetail() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const lookups = useLookups();
  const { data, isLoading, error } = useQuery({ queryKey: ['project', id], queryFn: () => api.get(`/projects/${id}`) });
  const [bc, setBc] = useState<any>(null);
  const [vo, setVo] = useState<any>(null);
  const [openDoc, setOpenDoc] = useState<{ kind: 'budget-changes' | 'variations'; id: string } | null>(null);
  const [tab, setTab] = useState<'orders' | 'costs' | 'billing' | 'ledger'>('orders');
  const refresh = () => qc.invalidateQueries({ queryKey: ['project', id] });
  const onError = (e: Error) => { toast(e.message, 'error'); refresh(); };
  const newBc = useMutation({
    mutationFn: () => api.post(`/projects/${id}/budget-changes`, { reason: bc.reason, lines: bc.lines.filter((l: any) => l.amount !== '') }),
    onSuccess: (r) => { setBc(null); refresh(); setOpenDoc({ kind: 'budget-changes', id: r.id }); }, onError,
  });
  const newVo = useMutation({
    mutationFn: () => api.post(`/projects/${id}/variations`, Object.fromEntries(Object.entries(vo).filter(([, v]) => v !== ''))),
    onSuccess: (r) => { setVo(null); refresh(); setOpenDoc({ kind: 'variations', id: r.id }); }, onError,
  });
  const status = (s: string) => api.post(`/projects/${id}/status`, { status: s }).then(refresh, onError);

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const { project: p, summary: s, categories } = data;
  const cats = lookups.data?.cost_categories ?? [];
  const gp = Number(s.expected_gross_profit);
  return (
    <div className="space-y-4">
      <PageHeader
        title={<span className="flex flex-wrap items-center gap-2"><span className="font-mono">{p.number}</span> {p.name}<Status value={p.status} /></span>}
        subtitle={<>{pick(p.customer_name, p.customer_name_ar)} · {p.contract_number} · {p.quotation_number}{p.project_manager_name && <> · {t('project.pm')}: {p.project_manager_name}</>}</>}
        actions={<>
          {can('budgets.write') && <Button variant="secondary" data-testid="new-bc" onClick={() => setBc({ reason: '', lines: cats.filter((c: any) => c.code !== 'general').map((c: any) => ({ cost_category: c.code, amount: '' })) })}><Plus className="h-4 w-4" />{t('fin.budgetChange')}</Button>}
          {can('budgets.write') && <Button variant="secondary" data-testid="new-vo" onClick={() => setVo({ title: '', customer_reference: '', value: '', cost_impact: '', cost_category: 'general', description: '' })}><Plus className="h-4 w-4" />{t('fin.variation')}</Button>}
          {can('quotations.award') && <Select className="w-40" value={p.status} onChange={(e) => status(e.target.value)} aria-label={t('common.status')}>
            {['planning', 'active', 'on_hold', 'completed', 'closed', 'cancelled'].map((x) => <option key={x} value={x}>{t(`fin.status.${x}`)}</option>)}
          </Select>}
        </>} />

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4 xl:grid-cols-6" data-testid="project-summary">
        <Stat label={t('fin.customerPoValue')} value={money(s.customer_po_value)} />
        <Stat label={t('fin.contractValue')} value={money(s.contract_value)} sub={`${t('fin.original')} ${money(s.original_contract_value)} + ${t('fin.variations')} ${money(s.approved_variations)}`} testId="sum-contract" />
        <Stat label={t('fin.approvedBudget')} value={money(s.approved_budget)} testId="sum-budget" />
        <Stat label={t('fin.committed')} value={money(s.supplier_po_commitments)} sub={t('fin.committedHint')} testId="sum-committed" />
        <Stat label={t('fin.actualCost')} value={money(s.actual_cost)} sub={`${t('fin.supplierInvoiced')} ${money(s.supplier_invoiced)}`} testId="sum-actual" />
        <Stat label={t('fin.budgetRemaining')} value={money(s.budget_remaining)} tone={Number(s.budget_remaining) < 0 ? 'red' : undefined} testId="sum-remaining" />
        <Stat label={t('fin.forecastCost')} value={money(s.forecast_final_cost)} sub={`${t('fin.vsBudget')} ${money(s.forecast_variance)}`} testId="sum-forecast" />
        <Stat label={t('fin.grossProfit')} value={money(s.expected_gross_profit)} sub={s.expected_margin_pct !== null ? `${s.expected_margin_pct}%` : undefined} tone={gp < 0 ? 'red' : 'green'} testId="sum-gp" />
        <Stat label={t('fin.billed')} value={money(s.billed_to_customer)} sub={`${t('fin.leftToBill')} ${money(s.left_to_bill)}`} />
        <Stat label={t('fin.receivedFromCustomer')} value={money(s.received_from_customer)} sub={`${t('fin.outstanding')} ${money(s.receivable_outstanding)}`} />
        <Stat label={t('fin.retentionHeld')} value={money(s.retention_held_by_customer)} sub={`${t('fin.advancesOpen')} ${money(s.advances_open)}`} />
        <Stat label={t('fin.supplierPayable')} value={money(s.supplier_payable_open)} sub={`${t('fin.paid')} ${money(s.supplier_paid)}`} />
      </div>
      {(s.pending_variation_count > 0 || s.over_budget_orders > 0 || s.pending_supplier_orders > 0) && (
        <div className="flex flex-wrap gap-3 text-xs">
          {s.pending_variation_count > 0 && <span className="rounded bg-amber-50 px-2 py-1 text-amber-800">{t('fin.pendingVariations', { count: s.pending_variation_count, value: money(s.pending_variations) })}</span>}
          {s.over_budget_orders > 0 && <span className="rounded bg-red-50 px-2 py-1 text-red-800">{t('fin.overBudgetOrders', { count: s.over_budget_orders })}</span>}
          {s.pending_supplier_orders > 0 && <span className="rounded bg-slate-100 px-2 py-1 text-slate-700">{t('fin.pendingOrders', { count: s.pending_supplier_orders })}</span>}
        </div>
      )}

      <Card title={t('fin.costByCategory')} bodyClass="p-0">
        <div className="overflow-x-auto"><table className="w-full text-sm" data-testid="cost-categories"><thead className="bg-slate-50"><tr>
          <th className="th">{t('fin.costCategory')}</th><th className="th text-end">{t('fin.budget')}</th><th className="th text-end">{t('fin.committed')}</th>
          <th className="th text-end">{t('fin.actualCost')}</th><th className="th text-end">{t('fin.supplierInvoiced')}</th><th className="th text-end">{t('fin.available')}</th>
        </tr></thead><tbody className="divide-y">
          {categories.map((c: any) => (
            <tr key={c.cost_category}><td className="td">{pick(c.name_en, c.name_ar)}</td><td className="td num">{money(c.budget)}</td><td className="td num">{money(c.committed)}</td>
              <td className="td num">{money(c.actual)}</td><td className="td num">{money(c.invoiced)}</td><td className={cx('td num', Number(c.available) < 0 && 'font-semibold text-red-700')}>{money(c.available)}</td></tr>
          ))}
        </tbody></table></div>
        <p className="border-t px-4 py-2 text-xs text-slate-500">{t('fin.noDoubleCount')}</p>
      </Card>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card title={t('fin.budgetChanges')} bodyClass="p-0">
          {!data.budget_changes.length ? <Empty>{t('fin.budgetChangeHint')}</Empty> : <table className="w-full text-sm"><tbody className="divide-y">
            {data.budget_changes.map((b: any) => (
              <tr key={b.id}><td className="td font-mono text-xs"><button className="link" onClick={() => setOpenDoc({ kind: 'budget-changes', id: b.id })}>{b.number}</button></td>
                <td className="td">{b.reason}</td><td className="td"><Status value={b.status} /></td><td className="td num">{money(b.total_change)}</td></tr>
            ))}
          </tbody></table>}
        </Card>
        <Card title={t('fin.variations')} bodyClass="p-0">
          {!data.variations.length ? <Empty /> : <table className="w-full text-sm"><tbody className="divide-y">
            {data.variations.map((v: any) => (
              <tr key={v.id}><td className="td font-mono text-xs"><button className="link" onClick={() => setOpenDoc({ kind: 'variations', id: v.id })}>{v.number}</button></td>
                <td className="td">{v.title}{v.customer_reference && <span className="text-xs text-slate-400"> · {v.customer_reference}</span>}</td><td className="td"><Status value={v.status} /></td>
                <td className="td num">{money(v.value)}<div className="text-xs text-slate-400">{t('fin.cost')} {money(v.cost_impact)}</div></td></tr>
            ))}
          </tbody></table>}
        </Card>
      </div>

      <div className="inline-flex overflow-hidden rounded-md border bg-white text-sm">
        {(['orders', 'costs', 'billing', 'ledger'] as const).map((k) => (
          <button key={k} className={cx('px-3 py-1.5', tab === k ? 'bg-brand-50 font-medium text-brand-800' : 'text-slate-600 hover:bg-slate-50')} onClick={() => setTab(k)}>{t(`fin.ptab.${k}`)}</button>
        ))}
      </div>
      {tab === 'orders' && <Card bodyClass="p-0">
        <List rows={data.customer_pos} cols={(o: any) => [<Link key="n" className="link font-mono text-xs" to={`/customer-pos/${o.id}`}>{o.number}</Link>, `${o.customer_po_number} · ${t(`fin.poType.${o.po_type}`)}`, <Status key="s" value={o.status} />, money(o.amount), `${t('fin.billed')} ${money(o.billed)}`]} />
      </Card>}
      {tab === 'costs' && <div className="grid gap-4 lg:grid-cols-2">
        <Card title={t('pur.orders')} bodyClass="p-0">
          <List rows={data.purchase_orders} cols={(o: any) => [<Link key="n" className="link font-mono text-xs" to={`/purchases/orders/${o.id}`}>{o.number ?? t('pur.draft')}</Link>, o.supplier_name, <Status key="s" value={o.status} />, money(o.taxable_amount), o.over_budget ? <span key="o" className="text-xs text-red-700">{t('fin.overBudget')}</span> : '']} />
        </Card>
        <Card title={t('fin.supplierInvoices')} bodyClass="p-0">
          <List rows={data.supplier_invoices} cols={(b: any) => [<Link key="n" className="link font-mono text-xs" to={`/supplier-invoices/${b.id}`}>{b.number}</Link>, `${b.supplier_name} · ${b.supplier_invoice_number}`, <Status key="s" value={b.status} />, money(b.subtotal), `${t('fin.paid')} ${money(b.amount_paid)}`]} />
        </Card>
      </div>}
      {tab === 'billing' && <Card bodyClass="p-0">
        <List rows={data.invoices} cols={(i: any) => [<Link key="n" className="link font-mono text-xs" to={`/invoices/${i.id}`}>{i.number ?? t('pur.draft')}</Link>, `${t(`inv.kind.${i.kind}`)} · ${t(`fin.billing.${i.billing_type ?? 'standard'}`)}`, <Status key="s" value={i.status} />, money(i.total_amount), `${t('fin.paid')} ${money(i.amount_paid)}`]} />
      </Card>}
      {tab === 'ledger' && <ProjectLedger id={id!} />}
      <Attachments entityType="project" entityId={p.id} canWrite={can('quotations.award')} />

      <Modal open={!!bc} onClose={() => setBc(null)} title={t('fin.budgetChange')} wide
        footer={<Button busy={newBc.isPending} onClick={() => newBc.mutate()} data-testid="save-bc">{t('common.create')}</Button>}>
        <ErrorBox error={newBc.error} />
        {bc && <>
          <Field label={t('common.reason')}><Input name="reason" value={bc.reason} onChange={(e) => setBc({ ...bc, reason: e.target.value })} /></Field>
          <p className="my-2 text-xs text-slate-500">{t('fin.budgetChangeLinesHint')}</p>
          <div className="grid gap-2 sm:grid-cols-2">{bc.lines.map((l: any, i: number) => (
            <Field key={l.cost_category} label={catName(cats, l.cost_category)}><Input name={`bc_${l.cost_category}`} type="number" step="any" value={l.amount}
              onChange={(e) => setBc({ ...bc, lines: bc.lines.map((x: any, j: number) => (j === i ? { ...x, amount: e.target.value } : x)) })} /></Field>
          ))}</div>
        </>}
      </Modal>
      <Modal open={!!vo} onClose={() => setVo(null)} title={t('fin.variation')} wide
        footer={<Button busy={newVo.isPending} onClick={() => newVo.mutate()} data-testid="save-vo">{t('common.create')}</Button>}>
        <ErrorBox error={newVo.error} />
        {vo && <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('common.title')} className="sm:col-span-2"><Input name="title" value={vo.title} onChange={(e) => setVo({ ...vo, title: e.target.value })} /></Field>
          <Field label={t('fin.customerRef')}><Input name="customer_reference" value={vo.customer_reference} onChange={(e) => setVo({ ...vo, customer_reference: e.target.value })} /></Field>
          <Field label={t('fin.voValue')}><Input name="value" type="number" step="any" value={vo.value} onChange={(e) => setVo({ ...vo, value: e.target.value })} /></Field>
          <Field label={t('fin.voCost')} hint={t('fin.voCostHint')}><Input name="cost_impact" type="number" step="any" value={vo.cost_impact} onChange={(e) => setVo({ ...vo, cost_impact: e.target.value })} /></Field>
          <Field label={t('fin.costCategory')}><Select name="cost_category" value={vo.cost_category} onChange={(e) => setVo({ ...vo, cost_category: e.target.value })}>
            {cats.map((c: any) => <option key={c.code} value={c.code}>{pick(c.name_en, c.name_ar)}</option>)}</Select></Field>
          <Field label={t('common.description')} className="sm:col-span-2"><Textarea value={vo.description} onChange={(e) => setVo({ ...vo, description: e.target.value })} /></Field>
        </div>}
      </Modal>
      {openDoc && <ChangeDoc kind={openDoc.kind} id={openDoc.id} onClose={() => setOpenDoc(null)} onChanged={refresh} />}
    </div>
  );
}

function List({ rows, cols }: { rows: any[]; cols: (r: any) => React.ReactNode[] }) {
  if (!rows.length) return <Empty />;
  return <table className="w-full text-sm"><tbody className="divide-y">{rows.map((r) => (
    <tr key={r.id}>{cols(r).map((c, i) => <td key={i} className={cx('td', i >= 3 && 'num')}>{c}</td>)}</tr>
  ))}</tbody></table>;
}

function ProjectLedger({ id }: { id: string }) {
  const { t } = useTranslation();
  const { can } = useAuth();
  const { data, isLoading, error } = useQuery({ queryKey: ['project-ledger', id], queryFn: () => api.get(`/projects/${id}/ledger`), enabled: can('accounting.read') });
  if (!can('accounting.read')) return <Card><p className="text-sm text-slate-500">{t('common.noPermission')}</p></Card>;
  return (
    <Card bodyClass="p-0">
      {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : !data.length ? <Empty /> : (
        <div className="overflow-x-auto"><table className="w-full text-xs"><thead className="bg-slate-50"><tr>
          <th className="th">{t('common.date')}</th><th className="th">{t('fin.entry')}</th><th className="th">{t('fin.account')}</th><th className="th">{t('common.description')}</th>
          <th className="th text-end">{t('fin.debit')}</th><th className="th text-end">{t('fin.credit')}</th>
        </tr></thead><tbody className="divide-y">{data.map((l: any, i: number) => (
          <tr key={i}><td className="td">{date(l.entry_date)}</td><td className="td font-mono">{l.number}</td><td className="td">{l.account_code} {l.account_name}</td>
            <td className="td">{l.description ?? l.memo}</td><td className="td num">{Number(l.debit) ? money(l.debit) : ''}</td><td className="td num">{Number(l.credit) ? money(l.credit) : ''}</td></tr>
        ))}</tbody></table></div>
      )}
    </Card>
  );
}

/** A budget change or variation: lines, approvals, and the submit/approve/reject buttons. */
function ChangeDoc({ kind, id, onClose, onChanged }: { kind: 'budget-changes' | 'variations'; id: string; onClose: () => void; onChanged: () => void }) {
  const { t } = useTranslation();
  const { can, me } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const reason = useReason();
  const lookups = useLookups();
  const { data: d, isLoading } = useQuery({ queryKey: [kind, id], queryFn: () => api.get(`/${kind}/${id}`) });
  const act = (a: string, comment?: string) => api.post(`/${kind}/${id}/${a}`, comment ? { comment } : {})
    .then(() => { qc.invalidateQueries({ queryKey: [kind, id] }); onChanged(); }, (e: Error) => toast(e.message, 'error'));
  const mine = d?.requested_by === me?.id;
  const selfOk = !!me?.allow_self_approval && !me?.segregation_of_duties;
  const canApprove = d?.status === 'submitted' && can('budgets.approve') && (!mine || selfOk);
  return (
    <Modal open onClose={onClose} wide title={<span className="flex items-center gap-2">{kind === 'variations' ? t('fin.variation') : t('fin.budgetChange')} {d?.number} <Status value={d?.status} /></span>}
      footer={d && <>
        {d.status === 'draft' && <Button onClick={() => act('submit')} data-testid="doc-submit">{t('pur.submit')}</Button>}
        {d.status === 'submitted' && mine && <Button variant="secondary" onClick={() => act('withdraw')}>{t('quote.withdraw')}</Button>}
        {canApprove && <><Button variant="danger" onClick={() => reason.ask(t('quote.reject'), (c) => act('reject', c), { danger: true })}>{t('quote.reject')}</Button>
          <Button variant="success" onClick={() => act('approve')} data-testid="doc-approve">{t('quote.approve')}</Button></>}
        {['draft', 'submitted'].includes(d.status) && <Button variant="ghost" onClick={() => act('cancel')}>{t('common.cancel')}</Button>}
      </>}>
      {isLoading || !d ? <Spinner /> : (
        <div className="space-y-3">
          <p className="text-sm">{d.reason ?? d.title}{d.description && <span className="block text-slate-500">{d.description}</span>}</p>
          <dl className="space-y-1 text-sm">
            {kind === 'budget-changes' ? <>
              {d.lines.map((l: any) => <Row key={l.id} label={pick(l.name_en, l.name_ar)}>{money(l.amount)}</Row>)}
              <Row label={t('common.total')} strong>{money(d.total_change)}</Row>
            </> : <>
              <Row label={t('fin.voValue')}>{money(d.value)}</Row>
              <Row label={t('fin.voCost')}>{money(d.cost_impact)} · {catName(lookups.data?.cost_categories, d.cost_category)}</Row>
              {d.customer_reference && <Row label={t('fin.customerRef')}>{d.customer_reference}</Row>}
            </>}
            <Row label={t('fin.requestedBy')}>{d.requested_by_name}</Row>
            {d.decided_by_name && <Row label={t('pur.decidedBy')}>{d.decided_by_name}</Row>}
          </dl>
          {d.decision_comment && <div className="rounded border bg-slate-50 p-2 text-sm">“{d.decision_comment}”</div>}
          <Approvals info={d.approvals} />
          <Attachments entityType={kind === 'variations' ? 'variation' : 'budget_change'} entityId={d.id} canWrite={can('budgets.write')} />
        </div>
      )}
      {reason.modal}
    </Modal>
  );
}
