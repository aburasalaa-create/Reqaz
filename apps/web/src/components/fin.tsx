// Shared pieces for the purchase order and finance screens.
import { useState, type ReactNode } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Check, Circle } from 'lucide-react';
import { api } from '../lib/api';
import { dateTime, money, pick } from '../lib/format';
import { Badge, Button, Card, Field, Modal, Textarea, type Tone } from './ui';

export const useLookups = () => useQuery({ queryKey: ['lookups'], queryFn: () => api.get('/lookups'), staleTime: 5 * 60_000 });

const FIN_TONES: Record<string, Tone> = {
  draft: 'slate', received: 'blue', under_review: 'amber', clarification_required: 'amber', accepted: 'green', rejected: 'red',
  active: 'green', completed: 'violet', closed: 'slate', cancelled: 'red', superseded: 'slate', pending_approval: 'amber',
  approved: 'blue', issued: 'cyan', partially_received: 'amber', submitted: 'amber', posted: 'green', matched: 'green',
  variance: 'red', no_po: 'slate', planning: 'slate', on_hold: 'amber', won: 'green', paid: 'green',
};

/** Status badge for the finance screens; labels live under fin.status. */
export function Status({ value }: { value: string | null | undefined }) {
  const { t } = useTranslation();
  if (!value) return null;
  return <Badge tone={FIN_TONES[value] ?? 'slate'}>{t(`fin.status.${value}`, { defaultValue: value.replace(/_/g, ' ') })}</Badge>;
}

/** A label and value row in a definition list. */
export function Row({ label, children, strong, testId }: { label: ReactNode; children: ReactNode; strong?: boolean; testId?: string }) {
  return (
    <div className={strong ? 'flex justify-between gap-3 border-t pt-1.5 font-semibold' : 'flex justify-between gap-3'}>
      <dt className={strong ? '' : 'text-slate-500'}>{label}</dt><dd className="num text-end" data-testid={testId}>{children}</dd>
    </div>
  );
}

/** A figure on a dashboard. */
export function Stat({ label, value, sub, tone, testId }: { label: ReactNode; value: ReactNode; sub?: ReactNode; tone?: 'red' | 'green' | 'amber'; testId?: string }) {
  const color = tone === 'red' ? 'text-red-700' : tone === 'green' ? 'text-emerald-700' : tone === 'amber' ? 'text-amber-700' : 'text-slate-900';
  return (
    <div className="card p-3">
      <div className="text-xs text-slate-500">{label}</div>
      <div className={`mt-1 text-lg font-semibold tabular-nums ${color}`} data-testid={testId}>{value}</div>
      {sub && <div className="mt-0.5 text-xs text-slate-400">{sub}</div>}
    </div>
  );
}

/** Approval levels needed at this amount, which are signed, and the full history. */
export function Approvals({ info }: { info?: { levels: any[]; history: any[] } }) {
  const { t } = useTranslation();
  if (!info) return null;
  // With no levels set up, the database reports a single level 0 that anyone with the approve permission can sign.
  const levels = info.levels.filter((l) => l.level > 0 || l.role_name);
  return (
    <Card title={t('fin.approvals')}>
      {levels.length > 0 ? (
        <ol className="mb-3 space-y-1 text-sm" data-testid="approval-levels">
          {levels.map((l) => (
            <li key={l.level} className="flex items-center gap-2">
              {l.signed ? <Check className="h-4 w-4 text-emerald-600" /> : <Circle className="h-4 w-4 text-slate-300" />}
              <span>{t('fin.level')} {l.level}: {l.role_name ?? t('fin.anyApprover')}</span>
              <span className="text-xs text-slate-400">{t('fin.from')} {money(l.min_amount)}</span>
            </li>
          ))}
        </ol>
      ) : <p className="mb-3 text-xs text-slate-500">{t('fin.oneApproval')}</p>}
      {info.history.length > 0 ? (
        <ul className="space-y-1.5 border-t pt-2 text-xs">
          {info.history.map((h) => (
            <li key={h.id}>
              <span className="font-medium text-slate-700">{t(`fin.act.${h.action}`, { defaultValue: h.action })}</span>
              {h.level ? <> · {t('fin.level')} {h.level}</> : null} · {h.actor_name ?? 'system'} · <span className="text-slate-400">{dateTime(h.created_at)}</span>
              {h.comment && <div className="text-slate-500">“{h.comment}”</div>}
            </li>
          ))}
        </ul>
      ) : <p className="border-t pt-2 text-xs text-slate-400">{t('fin.noHistory')}</p>}
    </Card>
  );
}

/** Ask for a comment or reason, then run the action. */
export function useReason() {
  const [state, setState] = useState<{ title: string; required: boolean; run: (text: string) => unknown; label?: string; danger?: boolean } | null>(null);
  const [text, setText] = useState('');
  const { t } = useTranslation();
  const ask = (title: string, run: (text: string) => unknown, opts: { required?: boolean; label?: string; danger?: boolean } = {}) => {
    setText(''); setState({ title, run, required: opts.required ?? true, label: opts.label, danger: opts.danger });
  };
  const modal = (
    <Modal open={!!state} onClose={() => setState(null)} title={state?.title ?? ''}
      footer={<Button variant={state?.danger ? 'danger' : 'primary'} data-testid="reason-confirm" disabled={!!state?.required && !text.trim()}
        onClick={async () => { const s = state!; setState(null); await s.run(text.trim()); }}>{t('common.confirm')}</Button>}>
      <Field label={state?.label ?? t('common.comment')}><Textarea name="reason" value={text} onChange={(e) => setText(e.target.value)} autoFocus /></Field>
    </Modal>
  );
  return { ask, modal };
}

export const catName = (cats: any[] | undefined, code: string | null | undefined) => {
  const c = cats?.find((x) => x.code === code);
  return c ? pick(c.name_en, c.name_ar) : code ?? '';
};

export const today = () => new Date().toISOString().slice(0, 10);
