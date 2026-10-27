import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Check, Plus, RotateCcw, Trash2 } from 'lucide-react';
import { FOLLOW_UP_TYPES, OPPORTUNITY_STAGES } from '@rms/shared';
import { api } from '../lib/api';
import { useAuth } from '../lib/auth';
import { date, dateTime, money, toLocalInput } from '../lib/format';
import Attachments from '../components/Attachments';
import NewQuotation from '../components/NewQuotation';
import { EMPTY_TENDER, TenderFields, cleanTender } from '../components/TenderForm';
import { OpportunityFields, cleanOpp, useLookups, type OppForm } from '../components/OpportunityForm';
import { Badge, Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Select, Spinner, STATUS_TONE, Textarea, cx, useToast } from '../components/ui';

export default function OpportunityDetail() {
  const { id } = useParams();
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const { data: lk } = useLookups();
  const { data: o, isLoading, error } = useQuery({ queryKey: ['opportunity', id], queryFn: () => api.get(`/opportunities/${id}`) });
  const [form, setForm] = useState<OppForm>({});
  const [fu, setFu] = useState<any>(null);
  const [tender, setTender] = useState<any>(null);
  const [quoteOpen, setQuoteOpen] = useState(false);
  const [lost, setLost] = useState<string | null>(null);
  useEffect(() => { if (o) setForm(o); }, [o]);
  const refresh = () => { qc.invalidateQueries({ queryKey: ['opportunity', id] }); qc.invalidateQueries({ queryKey: ['opportunities'] }); };
  const onErr = (e: Error) => toast(e.message, 'error');

  const save = useMutation({ mutationFn: () => api.patch(`/opportunities/${id}`, cleanOpp(form)), onSuccess: () => { refresh(); toast(t('common.saved')); }, onError: onErr });
  const stage = useMutation({ mutationFn: (b: any) => api.patch(`/opportunities/${id}`, b), onSuccess: refresh, onError: onErr });
  const addFu = useMutation({ mutationFn: () => api.post('/follow-ups', { ...fu, opportunity_id: id, due_at: new Date(fu.due_at).toISOString(), assigned_to: fu.assigned_to || undefined }), onSuccess: () => { refresh(); setFu(null); } });
  const doneFu = useMutation({ mutationFn: ({ fid, completed }: { fid: string; completed: boolean }) => api.patch(`/follow-ups/${fid}`, { completed }), onSuccess: refresh, onError: onErr });
  const delFu = useMutation({ mutationFn: (fid: string) => api.del(`/follow-ups/${fid}`), onSuccess: refresh, onError: onErr });
  const addTender = useMutation({ mutationFn: () => api.post('/tenders', { ...cleanTender(tender), opportunity_id: id }), onSuccess: () => { refresh(); setTender(null); } });

  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const w = can('crm.write');
  const closed = o.stage === 'won' || o.stage === 'lost';

  return (
    <div>
      <PageHeader
        title={<span className="flex flex-wrap items-center gap-2">{o.title}<Badge tone={STATUS_TONE[o.stage]}>{t(`stage.${o.stage}`)}</Badge></span>}
        subtitle={<><span className="font-mono">{o.number}</span> · {o.customer_id ? <Link className="link" to={`/customers/${o.customer_id}`}>{o.customer_name}</Link> : o.prospect_company} · {t(`source.${o.source}`)}</>}
        actions={<>
          {w && !closed && (
            <Select aria-label={t('opp.moveTo')} className="w-48" value="" onChange={(e) => { const s = e.target.value; if (s === 'lost') setLost(''); else if (s) stage.mutate({ stage: s }); }}>
              <option value="">{t('opp.moveTo')}…</option>
              {OPPORTUNITY_STAGES.filter((s) => s !== o.stage && s !== 'won').map((s) => <option key={s} value={s}>{t(`stage.${s}`)}</option>)}
            </Select>
          )}
          {can('quotations.write') && !closed && <Button variant="secondary" onClick={() => setQuoteOpen(true)} disabled={!o.customer_id} title={!o.customer_id ? t('opp.linkCustomer') : ''}><Plus className="h-4 w-4" />{t('quote.new')}</Button>}
          {w && <Button busy={save.isPending} onClick={() => save.mutate()}>{t('common.save')}</Button>}
        </>} />
      {o.stage === 'lost' && o.lost_reason && <div className="mb-4 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800">{t('opp.lostReason')}: {o.lost_reason}</div>}
      <div className="grid gap-4 xl:grid-cols-3">
        <div className="space-y-4 xl:col-span-2">
          <Card title={t('common.details')}><fieldset disabled={!w}><OpportunityFields v={form} set={(k, v) => setForm((f) => ({ ...f, [k]: v }))} /></fieldset></Card>
          <Card title={t('opp.quotations')} bodyClass="p-0">
            {o.quotations.length ? (
              <table className="w-full"><tbody className="divide-y">{o.quotations.map((q: any) => (
                <tr key={q.id}><td className="td"><Link className="link" to={`/quotations/${q.id}`}>{q.number}</Link> {q.title}</td>
                  <td className="td">R{q.revision_no} <Badge tone={STATUS_TONE[q.revision_status]}>{t(`revStatus.${q.revision_status}`)}</Badge></td>
                  <td className="td"><Badge tone={STATUS_TONE[q.status]}>{t(`quoteStatus.${q.status}`)}</Badge></td>
                  <td className="td num">{money(q.total_amount, q.currency)}</td></tr>
              ))}</tbody></table>
            ) : <Empty />}
          </Card>
          <Card title={t('opp.tenders')} bodyClass="p-0" actions={can('tenders.write') && !closed && <Button variant="secondary" onClick={() => setTender(EMPTY_TENDER)} disabled={!o.customer_id}><Plus className="h-4 w-4" />{t('tender.new')}</Button>}>
            {o.tenders.length ? (
              <table className="w-full"><tbody className="divide-y">{o.tenders.map((x: any) => (
                <tr key={x.id}><td className="td"><Link className="link" to={`/tenders/${x.id}`}>{x.number}</Link> {x.title}</td><td className="td">{x.client_reference}</td>
                  <td className="td">{dateTime(x.submission_deadline)}</td><td className="td"><Badge tone={STATUS_TONE[x.status]}>{t(`tenderStatus.${x.status}`)}</Badge></td></tr>
              ))}</tbody></table>
            ) : <Empty />}
          </Card>
        </div>
        <div className="space-y-4">
          <Card title={t('opp.followUps')} bodyClass="p-0" actions={w && <Button variant="secondary" onClick={() => setFu({ type: 'call', subject: '', due_at: toLocalInput(new Date(Date.now() + 86400000).toISOString()), assigned_to: '' })}><Plus className="h-4 w-4" />{t('common.add')}</Button>}>
            {o.follow_ups.length ? <ul className="divide-y">{o.follow_ups.map((f: any) => {
              const late = !f.completed_at && new Date(f.due_at) < new Date();
              return (
                <li key={f.id} className="flex items-start justify-between gap-2 px-4 py-2 text-sm">
                  <span className={cx(f.completed_at && 'text-slate-400 line-through')}><Badge>{t(`followUpType.${f.type}`)}</Badge> {f.subject}
                    <span className={cx('block text-xs', late ? 'text-red-600' : 'text-slate-400')}>{dateTime(f.due_at)} · {f.assigned_name}</span></span>
                  {w && <span className="flex">
                    <Button variant="ghost" aria-label={f.completed_at ? t('opp.reopen') : t('opp.complete')} onClick={() => doneFu.mutate({ fid: f.id, completed: !f.completed_at })}>{f.completed_at ? <RotateCcw className="h-4 w-4" /> : <Check className="h-4 w-4" />}</Button>
                    <Button variant="ghost" aria-label={t('common.delete')} onClick={() => delFu.mutate(f.id)}><Trash2 className="h-4 w-4" /></Button></span>}
                </li>
              );
            })}</ul> : <Empty />}
          </Card>
          <Attachments entityType="opportunity" entityId={id!} canWrite={w} />
          <Card title={t('opp.history')} bodyClass="p-0">
            <ul className="divide-y">{o.history.map((h: any) => (
              <li key={h.id} className="px-4 py-2 text-xs text-slate-600">{h.from_stage ? `${t(`stage.${h.from_stage}`)} → ` : ''}<strong>{t(`stage.${h.to_stage}`)}</strong>
                <span className="block text-slate-400">{dateTime(h.changed_at)} · {h.changed_by_name ?? '—'}</span></li>
            ))}</ul>
          </Card>
        </div>
      </div>

      {quoteOpen && <NewQuotation open onClose={() => setQuoteOpen(false)} opportunity={o} />}
      <Modal open={!!fu} onClose={() => setFu(null)} title={t('opp.newFollowUp')}
        footer={<><Button variant="secondary" onClick={() => setFu(null)}>{t('common.cancel')}</Button><Button busy={addFu.isPending} onClick={() => addFu.mutate()}>{t('common.add')}</Button></>}>
        <ErrorBox error={addFu.error} />
        {fu && <div className="grid gap-3 sm:grid-cols-2">
          <Field label={t('common.type')}><Select value={fu.type} onChange={(e) => setFu({ ...fu, type: e.target.value })}>{FOLLOW_UP_TYPES.map((x) => <option key={x} value={x}>{t(`followUpType.${x}`)}</option>)}</Select></Field>
          <Field label={t('opp.due')}><Input type="datetime-local" value={fu.due_at} onChange={(e) => setFu({ ...fu, due_at: e.target.value })} /></Field>
          <Field label={t('common.title')} className="sm:col-span-2"><Input name="fu_subject" value={fu.subject} onChange={(e) => setFu({ ...fu, subject: e.target.value })} /></Field>
          <Field label={t('common.owner')}><Select value={fu.assigned_to} onChange={(e) => setFu({ ...fu, assigned_to: e.target.value })}><option value="">—</option>{lk?.users.map((u: any) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</Select></Field>
        </div>}
      </Modal>
      <Modal open={!!tender} onClose={() => setTender(null)} title={t('tender.new')} wide
        footer={<><Button variant="secondary" onClick={() => setTender(null)}>{t('common.cancel')}</Button><Button busy={addTender.isPending} onClick={() => addTender.mutate()}>{t('common.create')}</Button></>}>
        <ErrorBox error={addTender.error} />
        {tender && <TenderFields v={tender} set={(k, v) => setTender((x: any) => ({ ...x, [k]: v }))} />}
      </Modal>
      <Modal open={lost !== null} onClose={() => setLost(null)} title={t('opp.markLost')}
        footer={<><Button variant="secondary" onClick={() => setLost(null)}>{t('common.cancel')}</Button><Button variant="danger" disabled={!lost?.trim()} onClick={() => { stage.mutate({ stage: 'lost', lost_reason: lost }); setLost(null); }}>{t('common.confirm')}</Button></>}>
        <Field label={t('opp.lostReason')}><Textarea value={lost ?? ''} onChange={(e) => setLost(e.target.value)} /></Field>
      </Modal>
      <div className="mt-2 text-xs text-slate-400">{t('common.created')}: {date(o.created_at)}</div>
    </div>
  );
}
