import i18n from './i18n';

const locale = () => (i18n.language === 'ar' ? 'ar-SA-u-nu-latn' : 'en-GB');

export const money = (v: string | number | null | undefined, currency?: string) => {
  if (v === null || v === undefined || v === '') return '—';
  const n = Number(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return currency ? `${currency} ${n}` : n;
};
export const compactMoney = (v: string | number | null | undefined, currency = 'SAR') => {
  if (v === null || v === undefined) return '—';
  return `${currency} ${Number(v).toLocaleString('en-US', { notation: 'compact', maximumFractionDigits: 1 })}`;
};
export const num = (v: string | number | null | undefined, dp = 3) =>
  v === null || v === undefined || v === '' ? '' : Number(v).toLocaleString('en-US', { maximumFractionDigits: dp });
export const date = (v: string | null | undefined) =>
  v ? new Date(v.length === 10 ? `${v}T00:00:00` : v).toLocaleDateString(locale(), { year: 'numeric', month: 'short', day: 'numeric' }) : '—';
export const dateTime = (v: string | null | undefined) =>
  v ? new Date(v).toLocaleString(locale(), { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';
export const toLocalInput = (v: string | null | undefined) => {
  if (!v) return '';
  const d = new Date(v);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
};
export const fromLocalInput = (v: string) => (v ? new Date(v).toISOString() : null);
export const daysUntil = (v: string) => Math.ceil((new Date(v).getTime() - Date.now()) / 86400000);
/** Pick the Arabic or English variant of a bilingual field. */
export const pick = (en?: string | null, ar?: string | null) => (i18n.language === 'ar' && ar ? ar : en ?? ar ?? '');
