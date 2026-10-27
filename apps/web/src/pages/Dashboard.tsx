import { useQuery } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { OPPORTUNITY_STAGES } from '@rms/shared';
import { api } from '../lib/api';
import { compactMoney, date, dateTime, daysUntil, money } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, PageHeader, Spinner } from '../components/ui';

export default function Dashboard() {
  const { t } = useTranslation();
  const { data, isLoading, error } = useQuery({ queryKey: ['dashboard'], queryFn: () => api.get('/dashboard') });
  if (isLoading) return <Spinner />;
  if (error) return <ErrorBox error={error} />;
  const pipe = data.pipeline as { stage: string; count: number; value: string; weighted: string }[];
  const total = pipe.reduce((a, p) => a + Number(p.value), 0);
  const weighted = pipe.reduce((a, p) => a + Number(p.weighted), 0);
  const count = pipe.reduce((a, p) => a + p.count, 0);
  const { won_12m, lost_12m } = data.stats;
  const winRate = won_12m + lost_12m ? Math.round((won_12m / (won_12m + lost_12m)) * 100) : null;
  const max = Math.max(1, ...pipe.map((p) => Number(p.value)));

  return (
    <div>
      <PageHeader title={t('dashboard.title')} />
      <div className="mb-4 grid grid-cols-2 gap-3 lg:grid-cols-4">
        {[
          [t('dashboard.pipeline'), compactMoney(total)],
          [t('dashboard.weighted'), compactMoney(weighted)],
          [t('dashboard.deals'), String(count)],
          [t('dashboard.winRate'), winRate === null ? '—' : `${winRate}%`],
        ].map(([k, v]) => (
          <div key={k} className="card p-4"><div className="text-xs text-slate-500">{k}</div><div className="mt-1 text-2xl font-semibold tabular-nums text-slate-900">{v}</div></div>
        ))}
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <Card title={t('dashboard.byStage')}>
          <div className="space-y-2">
            {OPPORTUNITY_STAGES.filter((s) => s !== 'won' && s !== 'lost').map((s) => {
              const p = pipe.find((x) => x.stage === s);
              return (
                <div key={s} className="grid grid-cols-[9rem_1fr_6rem] items-center gap-2 text-sm">
                  <span className="truncate text-slate-600">{t(`stage.${s}`)} <span className="text-slate-400">({p?.count ?? 0})</span></span>
                  <div className="h-3 rounded bg-slate-100"><div className="h-3 rounded bg-brand-500" style={{ width: `${(Number(p?.value ?? 0) / max) * 100}%` }} /></div>
                  <span className="text-end tabular-nums text-slate-700">{compactMoney(p?.value ?? 0)}</span>
                </div>
              );
            })}
          </div>
        </Card>
        <Card title={t('dashboard.approvals')} bodyClass="p-0">
          {data.pending_approvals.length ? (
            <ul className="divide-y">
              {data.pending_approvals.map((a: any) => (
                <li key={a.revision_id} className="flex items-center justify-between px-4 py-2 text-sm">
                  <Link className="link" to={`/quotations/${a.quotation_id}?rev=${a.revision_id}`}>{a.number} R{a.revision_no} — {a.title}</Link>
                  <span className="tabular-nums text-slate-600">{money(a.total_amount, a.currency)}</span>
                </li>
              ))}
            </ul>
          ) : <Empty />}
        </Card>
        <Card title={t('dashboard.deadlines')} bodyClass="p-0">
          {data.deadlines.length ? (
            <ul className="divide-y">
              {data.deadlines.map((d: any) => {
                const days = daysUntil(d.submission_deadline);
                return (
                  <li key={d.id} className="flex items-center justify-between gap-2 px-4 py-2 text-sm">
                    <span><Link className="link" to={`/tenders/${d.id}`}>{d.number}</Link> <span className="text-slate-600">{d.title}</span><span className="block text-xs text-slate-400">{d.customer_name}</span></span>
                    <span className="text-end">
                      <span className="block text-xs text-slate-500">{dateTime(d.submission_deadline)}</span>
                      <Badge tone={days <= 3 ? 'red' : days <= 7 ? 'amber' : 'slate'}>{days <= 0 ? t('dashboard.dueToday') : t('dashboard.daysLeft', { count: days })}</Badge>
                    </span>
                  </li>
                );
              })}
            </ul>
          ) : <Empty />}
        </Card>
        <Card title={t('dashboard.overdue')} bodyClass="p-0">
          {data.overdue_follow_ups.length ? (
            <ul className="divide-y">
              {data.overdue_follow_ups.map((f: any) => (
                <li key={f.id} className="flex items-center justify-between px-4 py-2 text-sm">
                  <span><Link className="link" to={`/opportunities/${f.opportunity_id}`}>{f.opportunity_number}</Link> {f.subject}<span className="block text-xs text-slate-400">{f.assigned_name}</span></span>
                  <Badge tone="red">{date(f.due_at)}</Badge>
                </li>
              ))}
            </ul>
          ) : <Empty />}
        </Card>
        <Card title={t('dashboard.wins')} bodyClass="p-0" className="lg:col-span-2">
          {data.recent_wins.length ? (
            <ul className="divide-y">
              {data.recent_wins.map((w: any) => (
                <li key={w.id} className="flex items-center justify-between px-4 py-2 text-sm">
                  <Link className="link" to={`/opportunities/${w.id}`}>{w.number} — {w.title}</Link>
                  <span className="tabular-nums">{w.original_value ? money(w.original_value, w.currency) : ''} <span className="text-xs text-slate-400">{date(w.stage_changed_at)}</span></span>
                </li>
              ))}
            </ul>
          ) : <Empty />}
        </Card>
      </div>
    </div>
  );
}
