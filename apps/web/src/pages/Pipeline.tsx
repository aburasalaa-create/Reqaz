import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { DndContext, PointerSensor, useDraggable, useDroppable, useSensor, useSensors, type DragEndEvent } from '@dnd-kit/core';
import { CalendarClock, Plus } from 'lucide-react';
import { OPPORTUNITY_STAGES, type OpportunityStage } from '@rms/shared';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { compactMoney, date, daysUntil } from '../lib/format';
import { Button, ErrorBox, Field, Input, Modal, PageHeader, Spinner, Textarea, cx, useToast } from '../components/ui';
import { EMPTY_OPP, OpportunityFields, cleanOpp, type OppForm } from '../components/OpportunityForm';

function OppCard({ o }: { o: any }) {
  const { t } = useTranslation();
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({ id: o.id, data: o });
  const style = transform ? { transform: `translate3d(${transform.x}px, ${transform.y}px, 0)` } : undefined;
  const deadline = o.next_tender_deadline ? daysUntil(o.next_tender_deadline) : null;
  const overdue = o.next_follow_up_at && new Date(o.next_follow_up_at) < new Date();
  return (
    <div ref={setNodeRef} style={style} {...listeners} {...attributes} data-testid={`opp-card-${o.number}`}
      className={cx('cursor-grab rounded-md border bg-white p-2.5 text-sm shadow-sm', isDragging && 'z-10 opacity-80 shadow-lg ring-2 ring-brand-500')}>
      <div className="flex items-start justify-between gap-1">
        <Link to={`/opportunities/${o.id}`} className="link font-medium leading-snug" onPointerDown={(e) => e.stopPropagation()}>{o.title}</Link>
      </div>
      <div className="mt-0.5 truncate text-xs text-slate-500">{o.customer_name ?? o.prospect_company ?? '—'}</div>
      <div className="mt-2 flex items-center justify-between text-xs">
        <span className="font-mono text-slate-400">{o.number}</span>
        <span className="font-medium tabular-nums text-slate-700">{o.expected_value ? compactMoney(o.expected_value, o.currency) : ''} {o.expected_value ? <span className="text-slate-400">· {o.win_probability}%</span> : null}</span>
      </div>
      {(deadline !== null || o.next_follow_up_at) && (
        <div className="mt-1.5 flex flex-wrap gap-1 text-[11px]">
          {deadline !== null && <span className={cx('rounded px-1.5 py-0.5', deadline <= 3 ? 'bg-red-100 text-red-700' : 'bg-amber-50 text-amber-700')}>{t('tender.deadline')}: {date(o.next_tender_deadline)}</span>}
          {o.next_follow_up_at && <span className={cx('inline-flex items-center gap-0.5 rounded px-1.5 py-0.5', overdue ? 'bg-red-100 text-red-700' : 'bg-slate-100 text-slate-600')}><CalendarClock className="h-3 w-3" />{date(o.next_follow_up_at)}</span>}
        </div>
      )}
    </div>
  );
}

function Column({ stage, items }: { stage: OpportunityStage; items: any[] }) {
  const { t } = useTranslation();
  const { setNodeRef, isOver } = useDroppable({ id: stage });
  const total = items.reduce((a, o) => a + Number(o.expected_value ?? 0), 0);
  return (
    <div ref={setNodeRef} data-testid={`col-${stage}`} className={cx('flex w-64 shrink-0 flex-col rounded-lg bg-slate-100/80 p-2', isOver && 'ring-2 ring-brand-500')}>
      <div className="mb-2 flex items-baseline justify-between px-1">
        <span className="text-xs font-semibold uppercase tracking-wide text-slate-600">{t(`stage.${stage}`)} <span className="text-slate-400">{items.length}</span></span>
        <span className="text-[11px] tabular-nums text-slate-500">{compactMoney(total)}</span>
      </div>
      <div className="flex min-h-[4rem] flex-1 flex-col gap-2">{items.map((o) => <OppCard key={o.id} o={o} />)}</div>
    </div>
  );
}

export default function Pipeline() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const toast = useToast();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [q, setQ] = useState('');
  const [closed, setClosed] = useState(false);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<OppForm>(EMPTY_OPP);
  const [lost, setLost] = useState<{ id: string; reason: string } | null>(null);
  const key = ['opportunities', q, closed];
  const { data = [], isLoading, error } = useQuery({ queryKey: key, queryFn: () => api.get(`/opportunities${qs({ q, include_closed: closed, limit: 500 })}`) });
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }));
  const byStage = useMemo(() => Object.fromEntries(OPPORTUNITY_STAGES.map((s) => [s, data.filter((o: any) => o.stage === s)])), [data]);

  const move = useMutation({
    mutationFn: ({ id, stage, lost_reason }: { id: string; stage: string; lost_reason?: string }) => api.patch(`/opportunities/${id}`, { stage, lost_reason }),
    onMutate: async ({ id, stage }) => {
      await qc.cancelQueries({ queryKey: key });
      const prev = qc.getQueryData(key);
      qc.setQueryData(key, (old: any[]) => old.map((o) => (o.id === id ? { ...o, stage } : o)));
      return { prev };
    },
    onError: (e: Error, _v, ctx) => { qc.setQueryData(key, ctx?.prev); toast(e.message, 'error'); },
    onSettled: () => qc.invalidateQueries({ queryKey: ['opportunities'] }),
  });
  const create = useMutation({
    mutationFn: () => api.post('/opportunities', cleanOpp(form)),
    onSuccess: (o) => { qc.invalidateQueries({ queryKey: ['opportunities'] }); setOpen(false); setForm(EMPTY_OPP); nav(`/opportunities/${o.id}`); },
  });

  const onDragEnd = (e: DragEndEvent) => {
    const stage = e.over?.id as OpportunityStage | undefined;
    const o = e.active.data.current as any;
    if (!stage || !o || o.stage === stage) return;
    if (!can('crm.write')) return toast(t('common.noPermission'), 'error');
    if (stage === 'won') return toast(t('opp.wonByAward'), 'error');
    if (stage === 'lost') return setLost({ id: o.id, reason: '' });
    move.mutate({ id: o.id, stage });
  };

  return (
    <div>
      <PageHeader title={t('opp.title')} subtitle={t('opp.dragHint')}
        actions={<>
          <Input className="w-56" placeholder={t('common.search')} value={q} onChange={(e) => setQ(e.target.value)} />
          <label className="flex items-center gap-1 text-sm text-slate-600"><input type="checkbox" checked={closed} onChange={(e) => setClosed(e.target.checked)} />{t('opp.showClosed')}</label>
          {can('crm.write') && <Button onClick={() => setOpen(true)}><Plus className="h-4 w-4" />{t('opp.new')}</Button>}
        </>} />
      {isLoading ? <Spinner /> : error ? <ErrorBox error={error} /> : (
        <DndContext sensors={sensors} onDragEnd={onDragEnd}>
          <div className="flex gap-3 overflow-x-auto pb-4">
            {OPPORTUNITY_STAGES.map((s) => <Column key={s} stage={s} items={byStage[s]} />)}
          </div>
        </DndContext>
      )}
      <Modal open={open} onClose={() => setOpen(false)} title={t('opp.new')} wide
        footer={<><Button variant="secondary" onClick={() => setOpen(false)}>{t('common.cancel')}</Button><Button busy={create.isPending} onClick={() => create.mutate()}>{t('common.create')}</Button></>}>
        <ErrorBox error={create.error} />
        <OpportunityFields v={form} set={(k, v) => setForm((f) => ({ ...f, [k]: v }))} />
      </Modal>
      <Modal open={!!lost} onClose={() => setLost(null)} title={t('opp.markLost')}
        footer={<><Button variant="secondary" onClick={() => setLost(null)}>{t('common.cancel')}</Button>
          <Button variant="danger" disabled={!lost?.reason.trim()} onClick={() => { move.mutate({ id: lost!.id, stage: 'lost', lost_reason: lost!.reason }); setLost(null); }}>{t('common.confirm')}</Button></>}>
        <Field label={t('opp.lostReason')}><Textarea value={lost?.reason ?? ''} onChange={(e) => setLost((l) => l && { ...l, reason: e.target.value })} /></Field>
      </Modal>
    </div>
  );
}
