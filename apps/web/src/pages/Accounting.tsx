// Accounting: trial balance, journal entries, manual journals, chart of accounts and bank reconciliation.
import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Plus, Trash2 } from 'lucide-react';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { date, money, pick } from '../lib/format';
import { Badge, Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Select, Spinner, cx, useToast } from '../components/ui';
import { Row, today, useReason } from '../components/fin';

type Tab = 'trial' | 'journals' | 'bank' | 'accounts';

export default function Accounting() {
  const { t } = useTranslation();
  const [tab, setTab] = useState<Tab>('trial');
  return (
    <div>
      <PageHeader title={t('fin.accounting')} subtitle={t('fin.accountingHint')} />
      <div className="mb-3 inline-flex overflow-hidden rounded-md border bg-white text-sm">
        {(['trial', 'journals', 'bank', 'accounts'] as const).map((k) => (
          <button key={k} data-testid={`tab-${k}`} className={cx('px-3 py-1.5', tab === k ? 'bg-brand-50 font-medium text-brand-800' : 'text-slate-600 hover:bg-slate-50')} onClick={() => setTab(k)}>{t(`fin.atab.${k}`)}</button>
        ))}
      </div>
      {tab === 'trial' && <TrialBalance />}
      {tab === 'journals' && <Journals />}
      {tab === 'bank' && <BankRec />}
      {tab === 'accounts' && <Accounts />}
    </div>
  );
}

function TrialBalance() {
  const { t } = useTranslation();
  const [to, setTo] = useState('');
  const { data, isLoading, error } = useQuery({ queryKey: ['trial-balance', to], queryFn: () => api.get(`/trial-balance${qs({ to })}`) });
  return (
    <Card title={t('fin.trialBalance')} bodyClass="p-0" actions={<Input type="date" className="w-40" value={to} onChange={(e) => setTo(e.target.value)} aria-label={t('fin.asAt')} />}>
      {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : (
        <table className="w-full text-sm" data-testid="trial-balance"><thead className="bg-slate-50"><tr>
          <th className="th">{t('fin.account')}</th><th className="th">{t('common.type')}</th><th className="th text-end">{t('fin.debit')}</th><th className="th text-end">{t('fin.credit')}</th><th className="th text-end">{t('fin.balance')}</th>
        </tr></thead><tbody className="divide-y">
          {data.rows.map((r: any) => (
            <tr key={r.code}><td className="td"><span className="font-mono text-xs">{r.code}</span> {pick(r.name_en, r.name_ar)}</td><td className="td text-xs text-slate-500">{t(`fin.atype.${r.type}`)}</td>
              <td className="td num">{money(r.debit)}</td><td className="td num">{money(r.credit)}</td><td className="td num">{money(Number(r.debit) - Number(r.credit))}</td></tr>
          ))}
          <tr className="bg-slate-50 font-semibold"><td className="td" colSpan={2}>{t('common.total')} {data.balanced ? <Badge tone="green">{t('fin.balanced')}</Badge> : <Badge tone="red">{t('fin.notBalanced')}</Badge>}</td>
            <td className="td num" data-testid="tb-debit">{money(data.totals.debit)}</td><td className="td num" data-testid="tb-credit">{money(data.totals.credit)}</td><td /></tr>
        </tbody></table>
      )}
    </Card>
  );
}

function Journals() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const reason = useReason();
  const [q, setQ] = useState('');
  const [account, setAccount] = useState('');
  const accounts = useQuery({ queryKey: ['accounts'], queryFn: () => api.get('/accounts') });
  const { data, isLoading, error } = useQuery({ queryKey: ['journals', q, account], queryFn: () => api.get(`/journals${qs({ q, account, limit: 200 })}`) });
  const [j, setJ] = useState<any>(null);
  const post = useMutation({
    mutationFn: () => api.post('/journals', { entry_date: j.entry_date, memo: j.memo, lines: j.lines.filter((l: any) => l.account && (l.debit || l.credit)).map((l: any) => ({ account: l.account, debit: l.debit || undefined, credit: l.credit || undefined, description: l.description || undefined })) }),
    onSuccess: () => { setJ(null); qc.invalidateQueries({ queryKey: ['journals'] }); qc.invalidateQueries({ queryKey: ['trial-balance'] }); toast(t('fin.posted')); },
  });
  const dr = j ? j.lines.reduce((a: number, l: any) => a + Number(l.debit || 0), 0) : 0;
  const cr = j ? j.lines.reduce((a: number, l: any) => a + Number(l.credit || 0), 0) : 0;
  const blankLine = { account: '', debit: '', credit: '', description: '' };
  return (
    <Card title={t('fin.journals')} bodyClass="p-0" actions={<>
      <Input className="w-48" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
      <Select className="w-48" value={account} onChange={(e) => setAccount(e.target.value)}><option value="">{t('fin.allAccounts')}</option>
        {accounts.data?.map((a: any) => <option key={a.code} value={a.code}>{a.code} {pick(a.name_en, a.name_ar)}</option>)}</Select>
      {can('accounting.manage') && <Button onClick={() => setJ({ entry_date: today(), memo: '', lines: [{ ...blankLine }, { ...blankLine }] })}><Plus className="h-4 w-4" />{t('fin.manualJournal')}</Button>}
    </>}>
      {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : !data.length ? <Empty /> : (
        <div className="divide-y">{data.map((e: any) => (
          <div key={e.id} className="px-4 py-2">
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <span className="font-mono text-xs">{e.number}</span><span>{date(e.entry_date)}</span><span className="text-slate-500">{e.memo}</span>
              <Badge tone="slate">{t(`fin.source.${e.source_type}`, { defaultValue: e.source_type })}</Badge>
              {e.reverses_number && <Badge tone="amber">{t('fin.reverses')} {e.reverses_number}</Badge>}
              {e.reversed && <Badge tone="red">{t('fin.reversed')}</Badge>}
              {e.source_type === 'manual' && !e.reversed && !e.reverses_id && can('accounting.manage') && <button className="link ms-auto text-xs" onClick={() => reason.ask(t('fin.reverse'), (r) => api.post(`/journals/${e.id}/reverse`, { reason: r }).then(() => qc.invalidateQueries({ queryKey: ['journals'] }), (x: Error) => toast(x.message, 'error')))}>{t('fin.reverse')}</button>}
            </div>
            <table className="mt-1 w-full text-xs"><tbody>{e.lines.map((l: any, i: number) => (
              <tr key={i}><td className="w-1/2 py-0.5 ps-4"><span className="font-mono">{l.account_code}</span> {l.account_name}{l.description && <span className="text-slate-400"> · {l.description}</span>}</td>
                <td className="num py-0.5">{Number(l.debit) ? money(l.debit) : ''}</td><td className="num py-0.5">{Number(l.credit) ? money(l.credit) : ''}</td></tr>
            ))}</tbody></table>
          </div>
        ))}</div>
      )}
      <Modal open={!!j} onClose={() => setJ(null)} title={t('fin.manualJournal')} wide
        footer={<><span className={cx('me-auto text-sm', Math.abs(dr - cr) < 0.005 && dr > 0 ? 'text-emerald-700' : 'text-red-700')}>{t('fin.debit')} {money(dr)} · {t('fin.credit')} {money(cr)}</span>
          <Button busy={post.isPending} disabled={Math.abs(dr - cr) >= 0.005 || dr === 0} onClick={() => post.mutate()}>{t('fin.post')}</Button></>}>
        <ErrorBox error={post.error} />
        {j && <>
          <div className="mb-3 grid gap-3 sm:grid-cols-3">
            <Field label={t('common.date')}><Input type="date" value={j.entry_date} onChange={(e) => setJ({ ...j, entry_date: e.target.value })} /></Field>
            <Field label={t('common.description')} className="sm:col-span-2"><Input value={j.memo} onChange={(e) => setJ({ ...j, memo: e.target.value })} /></Field>
          </div>
          <table className="w-full text-sm"><thead className="bg-slate-50"><tr><th className="th">{t('fin.account')}</th><th className="th w-32 text-end">{t('fin.debit')}</th><th className="th w-32 text-end">{t('fin.credit')}</th><th className="th">{t('common.description')}</th><th /></tr></thead>
            <tbody className="divide-y">{j.lines.map((l: any, i: number) => {
              const set = (k: string, v: string) => setJ({ ...j, lines: j.lines.map((x: any, n: number) => (n === i ? { ...x, [k]: v } : x)) });
              return (
                <tr key={i}>
                  <td className="px-1 py-1"><Select value={l.account} onChange={(e) => set('account', e.target.value)}><option value="">{t('common.select')}</option>
                    {accounts.data?.filter((a: any) => a.is_active !== false).map((a: any) => <option key={a.code} value={a.code}>{a.code} {pick(a.name_en, a.name_ar)}</option>)}</Select></td>
                  <td className="px-1 py-1"><Input type="number" step="any" className="text-end" value={l.debit} onChange={(e) => set('debit', e.target.value)} /></td>
                  <td className="px-1 py-1"><Input type="number" step="any" className="text-end" value={l.credit} onChange={(e) => set('credit', e.target.value)} /></td>
                  <td className="px-1 py-1"><Input value={l.description} onChange={(e) => set('description', e.target.value)} /></td>
                  <td>{j.lines.length > 2 && <button className="p-1 text-slate-400 hover:text-red-600" aria-label={t('common.delete')} onClick={() => setJ({ ...j, lines: j.lines.filter((_: any, n: number) => n !== i) })}><Trash2 className="h-4 w-4" /></button>}</td>
                </tr>
              );
            })}</tbody></table>
          <Button variant="secondary" className="mt-2" onClick={() => setJ({ ...j, lines: [...j.lines, { ...blankLine }] })}><Plus className="h-4 w-4" />{t('common.add')}</Button>
        </>}
      </Modal>
      {reason.modal}
    </Card>
  );
}

function BankRec() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const accounts = useQuery({ queryKey: ['accounts'], queryFn: () => api.get('/accounts') });
  const banks = (accounts.data ?? []).filter((a: any) => a.is_bank);
  const [code, setCode] = useState('1010');
  const [opening, setOpening] = useState('');
  const { data, isLoading, error } = useQuery({ queryKey: ['bank-rec', code, opening], queryFn: () => api.get(`/bank-reconciliation/${code}${qs({ opening_balance: opening })}`), enabled: !!code });
  const [paste, setPaste] = useState<string | null>(null);
  const [book, setBook] = useState<any>(null);
  const refresh = () => qc.invalidateQueries({ queryKey: ['bank-rec'] });
  const onError = (e: Error) => { toast(e.message, 'error'); refresh(); };
  // One line per statement row: date, description, amount (money out negative), optional reference — tab, comma or semicolon separated.
  const parsed = (paste ?? '').split('\n').map((l) => l.trim()).filter(Boolean).map((l) => {
    const c = l.split(/\t|;|,(?=\s*-?\d)/).map((x) => x.trim());
    return { txn_date: c[0], description: c[1], amount: c[2]?.replace(/[^0-9.-]/g, ''), reference: c[3] || undefined };
  });
  const add = useMutation({ mutationFn: () => api.post(`/bank-reconciliation/${code}/lines`, parsed), onSuccess: () => { setPaste(null); refresh(); }, onError });
  const s = data?.summary;
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3">
        <Field label={t('fin.bankAccount')}><Select value={code} onChange={(e) => setCode(e.target.value)}>
          {banks.map((a: any) => <option key={a.code} value={a.code}>{a.code} · {pick(a.name_en, a.name_ar)}</option>)}</Select></Field>
        <Field label={t('fin.openingBalance')}><Input type="number" step="any" className="w-40" value={opening} onChange={(e) => setOpening(e.target.value)} /></Field>
        {can('accounting.manage') && <Button onClick={() => setPaste('')} data-testid="add-statement"><Plus className="h-4 w-4" />{t('fin.addStatementLines')}</Button>}
      </div>
      {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : <>
        <div className="grid gap-4 lg:grid-cols-3">
          <Card title={t('fin.reconciliation')}>
            <dl className="space-y-1.5 text-sm">
              <Row label={t('fin.statementBalance')} testId="rec-statement">{money(s.statement_balance)}</Row>
              <Row label={t('fin.ledgerBalance')} testId="rec-ledger">{money(s.ledger_balance)}</Row>
              <Row label={t('fin.unmatchedStatement')}>{money(s.unmatched_statement)}</Row>
              <Row label={t('fin.unmatchedLedger')}>{money(s.unmatched_ledger)}</Row>
              <Row label={t('fin.difference')} strong>{money(s.difference)}</Row>
            </dl>
            <div className="mt-2" data-testid="rec-status">{s.reconciled ? <Badge tone="green">{t('fin.reconciled')}</Badge> : <Badge tone="amber">{t('fin.notReconciled')}</Badge>}</div>
          </Card>
          <Card title={t('fin.statementLines')} bodyClass="p-0" className="lg:col-span-2">
            {!data.statement.length ? <Empty /> : <table className="w-full text-sm"><tbody className="divide-y">
              {data.statement.map((l: any) => (
                <tr key={l.id} data-testid="statement-row">
                  <td className="td">{date(l.txn_date)}</td><td className="td">{l.description}{l.reference && <div className="text-xs text-slate-400">{l.reference}</div>}</td>
                  <td className={cx('td num', Number(l.amount) < 0 && 'text-red-700')}>{money(l.amount)}</td>
                  <td className="td text-end text-xs">
                    {l.journal_line_id ? <>{l.journal_number} <Badge tone="green">{t('fin.matched')}</Badge> {can('accounting.manage') && <button className="link ms-1" onClick={() => api.post(`/bank-statement-lines/${l.id}/unmatch`).then(refresh, onError)}>{t('fin.unmatch')}</button>}</>
                      : can('accounting.manage') && <div className="flex flex-wrap justify-end gap-1">
                        {l.suggestions?.map((sid: string) => { const m = data.unmatched_ledger.find((x: any) => x.id === sid); return m && (
                          <Button key={sid} variant="success" onClick={() => api.post(`/bank-statement-lines/${l.id}/match`, { journal_line_id: sid }).then(refresh, onError)} data-testid="match-suggestion">{t('fin.matchTo')} {m.number}</Button>); })}
                        <Button variant="secondary" onClick={() => setBook({ id: l.id, account: '6000', memo: l.description })}>{t('fin.book')}</Button>
                        <button className="p-1 text-slate-400 hover:text-red-600" aria-label={t('common.delete')} onClick={() => api.del(`/bank-statement-lines/${l.id}`).then(refresh, onError)}><Trash2 className="h-4 w-4" /></button>
                      </div>}
                  </td>
                </tr>
              ))}
            </tbody></table>}
          </Card>
        </div>
        <Card title={t('fin.unmatchedLedgerItems')} bodyClass="p-0">
          {!data.unmatched_ledger.length ? <Empty /> : <table className="w-full text-sm"><tbody className="divide-y">
            {data.unmatched_ledger.map((l: any) => (
              <tr key={l.id}><td className="td">{date(l.entry_date)}</td><td className="td font-mono text-xs">{l.number}</td><td className="td">{l.description ?? l.memo}</td><td className="td num">{money(l.amount)}</td></tr>
            ))}
          </tbody></table>}
        </Card>
      </>}
      <Modal open={paste !== null} onClose={() => setPaste(null)} title={t('fin.addStatementLines')} wide
        footer={<Button busy={add.isPending} disabled={!parsed.length} onClick={() => add.mutate()} data-testid="statement-save">{t('common.add')} ({parsed.length})</Button>}>
        <ErrorBox error={add.error} />
        <p className="mb-2 text-xs text-slate-500">{t('fin.pasteHint')}</p>
        <textarea name="statement" rows={8} className="input font-mono text-xs" value={paste ?? ''} onChange={(e) => setPaste(e.target.value)} placeholder={'2026-12-10\tGLP claim 1\t200000\n2026-12-31\tBank charges\t-57.50'} />
      </Modal>
      <Modal open={!!book} onClose={() => setBook(null)} title={t('fin.book')}
        footer={<Button onClick={() => api.post(`/bank-statement-lines/${book.id}/post`, { account: book.account, memo: book.memo }).then(() => { setBook(null); refresh(); }, onError)}>{t('fin.post')}</Button>}>
        {book && <div className="grid gap-3">
          <p className="text-xs text-slate-500">{t('fin.bookHint')}</p>
          <Field label={t('fin.account')}><Select value={book.account} onChange={(e) => setBook({ ...book, account: e.target.value })}>
            {accounts.data?.filter((a: any) => a.code !== code).map((a: any) => <option key={a.code} value={a.code}>{a.code} {pick(a.name_en, a.name_ar)}</option>)}</Select></Field>
          <Field label={t('common.description')}><Input value={book.memo} onChange={(e) => setBook({ ...book, memo: e.target.value })} /></Field>
        </div>}
      </Modal>
    </div>
  );
}

function Accounts() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const { data, isLoading, error } = useQuery({ queryKey: ['accounts'], queryFn: () => api.get('/accounts') });
  const [a, setA] = useState<any>(null);
  const create = useMutation({ mutationFn: () => api.post('/accounts', Object.fromEntries(Object.entries(a).filter(([, v]) => v !== ''))), onSuccess: () => { setA(null); qc.invalidateQueries({ queryKey: ['accounts'] }); qc.invalidateQueries({ queryKey: ['lookups'] }); } });
  const toggle = (x: any) => api.patch(`/accounts/${x.code}`, { is_active: !x.is_active }).then(() => qc.invalidateQueries({ queryKey: ['accounts'] }), (e: Error) => toast(e.message, 'error'));
  return (
    <Card title={t('fin.chartOfAccounts')} bodyClass="p-0" actions={can('accounting.manage') && <Button onClick={() => setA({ code: '', name_en: '', name_ar: '', type: 'asset', is_bank: false, bank_name: '', iban: '' })}><Plus className="h-4 w-4" />{t('fin.newAccount')}</Button>}>
      {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : (
        <table className="w-full text-sm"><thead className="bg-slate-50"><tr><th className="th">{t('common.code')}</th><th className="th">{t('common.name')}</th><th className="th">{t('common.type')}</th><th className="th text-end">{t('fin.balance')}</th><th className="th" /></tr></thead>
          <tbody className="divide-y">{data.map((x: any) => (
            <tr key={x.code} className={x.is_active === false ? 'text-slate-400' : ''}><td className="td font-mono text-xs">{x.code}</td>
              <td className="td">{pick(x.name_en, x.name_ar)}{x.is_bank && <Badge tone="blue">{t('fin.bank')}</Badge>}{x.system_key && <span className="ms-1 text-xs text-slate-400">({t('fin.systemAccount')})</span>}</td>
              <td className="td text-xs">{t(`fin.atype.${x.type}`)}</td><td className="td num">{x.balance !== undefined ? money(x.balance) : ''}</td>
              <td className="td text-end">{can('accounting.manage') && !x.system_key && <button className="link text-xs" onClick={() => toggle(x)}>{x.is_active ? t('fin.deactivate') : t('fin.activate')}</button>}</td></tr>
          ))}</tbody></table>
      )}
      <Modal open={!!a} onClose={() => setA(null)} title={t('fin.newAccount')} footer={<Button busy={create.isPending} onClick={() => create.mutate()}>{t('common.create')}</Button>}>
        <ErrorBox error={create.error} />
        {a && <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('common.code')}><Input value={a.code} onChange={(e) => setA({ ...a, code: e.target.value })} /></Field>
          <Field label={t('common.type')}><Select value={a.type} onChange={(e) => setA({ ...a, type: e.target.value })}>{['asset', 'liability', 'equity', 'income', 'expense'].map((x) => <option key={x} value={x}>{t(`fin.atype.${x}`)}</option>)}</Select></Field>
          <Field label={t('common.name')}><Input value={a.name_en} onChange={(e) => setA({ ...a, name_en: e.target.value })} /></Field>
          <Field label={t('common.nameAr')}><Input value={a.name_ar} onChange={(e) => setA({ ...a, name_ar: e.target.value })} /></Field>
          {a.type === 'asset' && <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={a.is_bank} onChange={(e) => setA({ ...a, is_bank: e.target.checked })} />{t('fin.isBank')}</label>}
          {a.is_bank && <><Field label={t('fin.bankName')}><Input value={a.bank_name} onChange={(e) => setA({ ...a, bank_name: e.target.value })} /></Field>
            <Field label="IBAN"><Input value={a.iban} onChange={(e) => setA({ ...a, iban: e.target.value })} /></Field></>}
        </div>}
      </Modal>
    </Card>
  );
}
