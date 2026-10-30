// Expenses with receipts. Amounts and VAT are typed from the receipt; the "15%" button only fills in a suggestion the user can change.
import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Camera, Plus } from 'lucide-react';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { date, money } from '../lib/format';
import Attachments from '../components/Attachments';
import { Badge, Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Select, Spinner, Textarea, cx, useToast, type Tone } from '../components/ui';

const CATEGORIES = ['materials', 'fuel', 'transport', 'equipment_rent', 'subcontract', 'site_supplies', 'meals', 'accommodation',
  'travel', 'government_fees', 'office', 'utilities', 'telecom', 'maintenance', 'general'] as const;
const TONES: Record<string, Tone> = { draft: 'slate', submitted: 'amber', approved: 'green', rejected: 'red', paid: 'blue', cancelled: 'red' };
const vat15 = (amount: string) => (Number(amount) > 0 ? (Math.round(Number(amount) * 15) / 100).toFixed(2) : '');

function ExpenseFields({ v, set, disabled }: { v: any; set: (k: string, val: any) => void; disabled?: boolean }) {
  const { t } = useTranslation();
  const projects = useQuery({ queryKey: ['projects'], queryFn: () => api.get('/projects') });
  const f = (k: string) => ({ name: k, value: v[k] ?? '', disabled, onChange: (e: any) => set(k, e.target.value) });
  const total = (Number(v.amount) || 0) + (Number(v.vat_amount) || 0);
  return (
    <div className="grid gap-3 sm:grid-cols-2">
      <Field label={t('exp.description')} className="sm:col-span-2"><Input {...f('description')} placeholder={t('exp.descriptionHint')} /></Field>
      <Field label={t('exp.amount')}><Input type="number" step="0.01" min="0" inputMode="decimal" {...f('amount')} /></Field>
      <Field label={t('exp.vat')}>
        <div className="flex gap-2">
          <Input type="number" step="0.01" min="0" inputMode="decimal" {...f('vat_amount')} />
          {!disabled && <Button type="button" variant="secondary" onClick={() => set('vat_amount', vat15(v.amount))} title={t('exp.vatHint')}>15%</Button>}
        </div>
      </Field>
      <div className="sm:col-span-2 rounded-md bg-sand/40 px-3 py-2 text-sm">{t('exp.total')}: <strong className="tabular-nums" data-testid="exp-total">{money(total, 'SAR')}</strong></div>
      <Field label={t('exp.paidTo')}><Input {...f('supplier_name')} placeholder={t('exp.paidToHint')} /></Field>
      <Field label={t('common.date')}><Input type="date" {...f('expense_date')} /></Field>
      <Field label={t('exp.category')}><Select {...f('category')}>{CATEGORIES.map((c) => <option key={c} value={c}>{t(`exp.cat.${c}`)}</option>)}</Select></Field>
      <Field label={t('exp.project')}><Select {...f('project_id')}><option value="">—</option>
        {(projects.data ?? []).map((p: any) => <option key={p.id} value={p.id}>{p.number} — {p.name}</option>)}</Select></Field>
      <Field label={t('exp.paidBy')}><Select {...f('paid_by')}>
        <option value="company">{t('exp.byCompany')}</option><option value="employee">{t('exp.byEmployee')}</option></Select></Field>
      <Field label={t('exp.invoiceNo')}><Input {...f('supplier_invoice_number')} /></Field>
      <Field label={t('exp.supplierVat')}><Input {...f('supplier_vat_number')} inputMode="numeric" placeholder="3XXXXXXXXXXXXX3" /></Field>
      <Field label={t('common.notes')}><Input {...f('notes')} /></Field>
    </div>
  );
}

const today = () => new Date().toISOString().slice(0, 10);
const clean = (v: any) => Object.fromEntries(Object.entries(v).map(([k, x]) => [k, x === '' && k !== 'description' ? (k === 'vat_amount' ? '0' : null) : x]));

export function Expenses() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const nav = useNavigate();
  const [status, setStatus] = useState('');
  const [q, setQ] = useState('');
  const [form, setForm] = useState<any>(null);
  const [receipt, setReceipt] = useState<File | null>(null);
  const list = useQuery({ queryKey: ['expenses', status, q], queryFn: () => api.get(`/expenses${qs({ status, q })}`) });
  const sum = useQuery({ queryKey: ['expenses-summary'], queryFn: () => api.get('/expenses/summary') });
  const create = useMutation({
    mutationFn: async () => {
      const e = await api.post('/expenses', clean(form));
      if (receipt) {
        const fd = new FormData();
        fd.set('entity_type', 'expense'); fd.set('entity_id', e.id); fd.set('file', receipt);
        await api.upload('/attachments', fd);
      }
      return e;
    },
    onSuccess: (e) => nav(`/expenses/${e.id}`),
  });
  const open = () => { setReceipt(null); setForm({ description: '', amount: '', vat_amount: '', supplier_name: '', expense_date: today(), category: 'general', project_id: '', paid_by: 'company' }); };

  return (
    <div>
      <PageHeader title={t('nav.expenses')} actions={<>
        <Input className="w-48" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
        <Select className="w-40" value={status} onChange={(e) => setStatus(e.target.value)}><option value="">{t('common.all')}</option>
          {Object.keys(TONES).map((s) => <option key={s} value={s}>{t(`exp.status.${s}`)}</option>)}</Select>
        {can('expenses.write') && <Button onClick={open}><Plus className="h-4 w-4" />{t('exp.new')}</Button>}
      </>} />
      {sum.data && (
        <div className="mb-4 grid gap-3 sm:grid-cols-3">
          <Card><div className="text-xs text-slate-500">{t('exp.thisMonth')}</div><div className="text-xl font-semibold tabular-nums">{money(sum.data.this_month, 'SAR')}</div>
            <div className="text-xs text-slate-400">{t('exp.vatThisMonth')}: {money(sum.data.vat_this_month)}</div></Card>
          <Card><div className="text-xs text-slate-500">{t('exp.waiting')}</div><div className="text-xl font-semibold tabular-nums">{sum.data.waiting_count} · {money(sum.data.waiting_amount)}</div></Card>
          <Card><div className="text-xs text-slate-500">{t('exp.owedToStaff')}</div><div className="text-xl font-semibold tabular-nums">{money(sum.data.owed_to_staff, 'SAR')}</div></Card>
        </div>
      )}
      <Card bodyClass="p-0">
        {list.isLoading ? <Spinner /> : list.error ? <ErrorBox error={list.error} /> : !list.data.length ? <Empty /> : (
          <div className="overflow-x-auto"><table className="w-full min-w-[640px] text-sm"><thead className="bg-slate-50"><tr>
            <th className="th">{t('common.number')}</th><th className="th">{t('common.date')}</th><th className="th">{t('exp.description')}</th>
            <th className="th">{t('exp.paidTo')}</th><th className="th">{t('common.status')}</th><th className="th text-end">{t('exp.total')}</th>
          </tr></thead><tbody className="divide-y">
            {list.data.map((x: any) => (
              <tr key={x.id}>
                <td className="td font-mono text-xs"><Link className="link" to={`/expenses/${x.id}`}>{x.number}</Link></td>
                <td className="td">{date(x.expense_date)}</td>
                <td className="td">{x.description}{x.project_number && <span className="text-xs text-slate-400"> · {x.project_number}</span>}
                  {!x.receipts && <span className="ms-1 text-xs text-amber-700">({t('exp.noReceipt')})</span>}</td>
                <td className="td">{x.payee ?? '—'}</td>
                <td className="td"><Badge tone={TONES[x.status]}>{t(`exp.status.${x.status}`)}</Badge></td>
                <td className="td num">{money(x.total_amount, x.currency)}</td>
              </tr>
            ))}
          </tbody></table></div>
        )}
      </Card>

      <Modal open={!!form} onClose={() => setForm(null)} title={t('exp.new')} wide
        footer={<><Button variant="secondary" onClick={() => setForm(null)}>{t('common.cancel')}</Button><Button busy={create.isPending} onClick={() => create.mutate()}>{t('common.save')}</Button></>}>
        <ErrorBox error={create.error} />
        {form && <>
          <label className={cx('mb-3 flex cursor-pointer items-center gap-2 rounded-md border border-dashed px-3 py-3 text-sm', receipt ? 'border-emerald-400 bg-emerald-50' : 'border-slate-300 hover:bg-slate-50')}>
            <Camera className="h-5 w-5 text-slate-500" />
            <span>{receipt ? receipt.name : t('exp.addReceipt')}</span>
            <input type="file" accept="image/*,application/pdf" capture="environment" className="hidden" data-testid="receipt-input"
              onChange={(e) => setReceipt(e.target.files?.[0] ?? null)} />
          </label>
          <ExpenseFields v={form} set={(k, val) => setForm((f: any) => ({ ...f, [k]: val }))} />
        </>}
      </Modal>
    </div>
  );
}

export function ExpenseDetail() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { can, me } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const { data: e, isLoading, error } = useQuery({ queryKey: ['expense', id], queryFn: () => api.get(`/expenses/${id}`) });
  const [edit, setEdit] = useState<any>(null);
  const [reject, setReject] = useState<string | null>(null);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['expense', id] }); qc.invalidateQueries({ queryKey: ['expenses'] }); qc.invalidateQueries({ queryKey: ['expenses-summary'] }); };
  const onError = (err: Error) => { toast(err.message, 'error'); refresh(); };
  const save = useMutation({ mutationFn: () => {
    const { description, amount, vat_amount, supplier_name, expense_date, category, project_id, paid_by, supplier_invoice_number, supplier_vat_number, notes } = edit;
    return api.patch(`/expenses/${id}`, clean({ description, amount, vat_amount, supplier_name, expense_date, category, project_id, paid_by, supplier_invoice_number, supplier_vat_number, notes }));
  }, onSuccess: () => { setEdit(null); refresh(); toast(t('common.saved')); }, onError });
  const act = useMutation({ mutationFn: ({ a, b }: { a: string; b?: any }) => api.post(`/expenses/${id}/${a}`, b ?? {}), onSuccess: () => { setReject(null); refresh(); }, onError });

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const mine = e.created_by === me?.id;
  const draft = e.status === 'draft';
  const approver = can('expenses.approve');
  const selfOk = !mine || !!me?.allow_self_approval;
  const approveNow = async () => {
    try { if (draft) await api.post(`/expenses/${id}/submit`); await act.mutateAsync({ a: 'approve' }); } catch (err) { onError(err as Error); }
  };
  const v = edit ?? { ...e, project_id: e.project_id ?? '', vat_amount: e.vat_amount };

  return (
    <div className="space-y-4">
      <PageHeader
        title={<span className="flex flex-wrap items-center gap-2">{e.description}<Badge tone={TONES[e.status]}>{t(`exp.status.${e.status}`)}</Badge></span>}
        subtitle={<><span className="font-mono">{e.number}</span> · {e.created_by_name}{e.decided_by_name && <> · {t('pur.decidedBy')} {e.decided_by_name}</>}</>}
        actions={<>
          {draft && (mine || approver) && !edit && <Button variant="secondary" onClick={() => setEdit({ ...v })}>{t('common.edit')}</Button>}
          {approver && selfOk && ['draft', 'submitted'].includes(e.status) && (e.status === 'submitted' || mine) &&
            <Button variant="success" busy={act.isPending} onClick={approveNow} data-testid="approve-expense">{t('quote.approve')}</Button>}
          {draft && mine && <Button variant={approver && selfOk ? 'secondary' : undefined} onClick={() => act.mutate({ a: 'submit' })}>{t('pur.submit')}</Button>}
          {e.status === 'submitted' && approver && selfOk && <Button variant="danger" onClick={() => setReject('')}>{t('quote.reject')}</Button>}
          {e.status === 'submitted' && mine && <Button variant="secondary" onClick={() => act.mutate({ a: 'withdraw' })}>{t('quote.withdraw')}</Button>}
          {e.status === 'approved' && approver && <Button onClick={() => act.mutate({ a: 'pay' })} data-testid="pay-expense">{t('exp.markPaid')}</Button>}
          {['draft', 'submitted', 'rejected'].includes(e.status) && (mine || approver) && <Button variant="ghost" onClick={() => act.mutate({ a: 'cancel' })}>{t('common.cancel')}</Button>}
        </>} />
      {e.decision_comment && <div className="rounded-md border bg-slate-50 p-3 text-sm">“{e.decision_comment}”</div>}
      <div className="grid gap-4 lg:grid-cols-3">
        <Card title={t('inv.details')} className="lg:col-span-2" actions={edit && <>
          <Button variant="secondary" onClick={() => setEdit(null)}>{t('common.cancel')}</Button><Button busy={save.isPending} onClick={() => save.mutate()}>{t('common.save')}</Button></>}>
          <ExpenseFields v={v} set={(k, val) => setEdit((f: any) => ({ ...f, [k]: val }))} disabled={!edit} />
        </Card>
        <div className="space-y-4">
          <Card title={t('exp.total')}><div className="text-2xl font-semibold tabular-nums">{money(e.total_amount, e.currency)}</div>
            <div className="text-xs text-slate-500">{t('exp.amount')} {money(e.amount)} · {t('exp.vat')} {money(e.vat_amount)}</div>
            {e.paid_at && <div className="mt-1 text-xs text-slate-500">{t('exp.status.paid')}: {date(e.paid_at)}</div>}</Card>
          <Attachments entityType="expense" entityId={e.id} canWrite={draft && (mine || approver)} />
        </div>
      </div>
      <Modal open={reject !== null} onClose={() => setReject(null)} title={t('quote.reject')}
        footer={<Button variant="danger" busy={act.isPending} onClick={() => act.mutate({ a: 'reject', b: { comment: reject } })}>{t('quote.reject')}</Button>}>
        <Field label={t('pur.comment')}><Textarea value={reject ?? ''} onChange={(ev) => setReject(ev.target.value)} /></Field>
      </Modal>
    </div>
  );
}
