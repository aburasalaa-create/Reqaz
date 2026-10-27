import { NavLink, Outlet } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { BarChart3, Briefcase, Building2, ClipboardList, FileSpreadsheet, FileText, Inbox, KanbanSquare, LayoutTemplate, LogOut, Settings, ShieldCheck, Truck } from 'lucide-react';
import { useAuth } from '../lib/auth';
import { pick } from '../lib/format';
import { cx } from './ui';

export default function Layout() {
  const { t, i18n } = useTranslation();
  const { me, can, signOut } = useAuth();
  const groups = [
    { label: '', items: [{ to: '/', icon: BarChart3, label: t('nav.dashboard'), perm: 'dashboard.read', end: true }] },
    { label: t('nav.sales'), items: [
      { to: '/pipeline', icon: KanbanSquare, label: t('nav.pipeline'), perm: 'crm.read' },
      { to: '/leads', icon: Inbox, label: t('nav.leads'), perm: 'crm.read' },
      { to: '/customers', icon: Building2, label: t('nav.customers'), perm: 'customers.read' },
      { to: '/tenders', icon: ClipboardList, label: t('nav.tenders'), perm: 'tenders.read' },
    ] },
    { label: t('nav.estimating'), items: [
      { to: '/quotations', icon: FileText, label: t('nav.quotations'), perm: 'quotations.read' },
      { to: '/templates', icon: LayoutTemplate, label: t('nav.templates'), perm: 'estimation.read' },
      { to: '/suppliers', icon: Truck, label: t('nav.suppliers'), perm: 'suppliers.read' },
    ] },
    { label: t('nav.delivery'), items: [
      { to: '/projects', icon: Briefcase, label: t('nav.projects'), perm: ['contracts.read', 'projects.read', 'quotations.award'] },
    ] },
    { label: t('nav.system'), items: [
      { to: '/admin', icon: Settings, label: t('nav.admin'), perm: 'users.manage' },
      { to: '/audit', icon: ShieldCheck, label: t('nav.audit'), perm: 'audit.read' },
    ] },
  ];
  const allowed = (p: string | string[]) => (Array.isArray(p) ? p.some(can) : can(p));

  return (
    <div className="flex min-h-screen">
      <aside className="sticky top-0 hidden h-screen w-60 shrink-0 flex-col border-e border-slate-200 bg-white md:flex">
        <div className="flex items-center gap-2 border-b px-4 py-3">
          <div className="flex h-8 w-8 items-center justify-center rounded bg-brand-700 text-sm font-bold text-white"><FileSpreadsheet className="h-4 w-4" /></div>
          <div className="leading-tight">
            <div className="text-sm font-semibold text-slate-900">{i18n.language === 'ar' ? 'ركاز المتحدة' : 'Reqaz United'}</div>
            <div className="text-xs text-slate-500">{t('app.name')}</div>
          </div>
        </div>
        <nav className="flex-1 overflow-y-auto px-2 py-3">
          {groups.map((g) => {
            const items = g.items.filter((i) => allowed(i.perm));
            if (!items.length) return null;
            return (
              <div key={g.label || 'main'} className="mb-3">
                {g.label && <div className="px-2 pb-1 text-[11px] font-semibold uppercase tracking-wider text-slate-400">{g.label}</div>}
                {items.map((i) => (
                  <NavLink key={i.to} to={i.to} end={'end' in i} className={({ isActive }) => cx('flex items-center gap-2 rounded-md px-2 py-1.5 text-sm',
                    isActive ? 'bg-brand-50 font-medium text-brand-800' : 'text-slate-600 hover:bg-slate-50')}>
                    <i.icon className="h-4 w-4" />{i.label}
                  </NavLink>
                ))}
              </div>
            );
          })}
        </nav>
        <div className="border-t p-3 text-sm">
          <div className="font-medium text-slate-800">{pick(me?.full_name, me?.full_name_ar)}</div>
          <div className="mb-2 truncate text-xs text-slate-500">{me?.roles.map((r) => pick(r.name_en, r.name_ar)).join(', ')}</div>
          <div className="flex gap-2">
            <button className="rounded border px-2 py-1 text-xs text-slate-600 hover:bg-slate-50" onClick={() => i18n.changeLanguage(i18n.language === 'ar' ? 'en' : 'ar')}>{t('common.language')}</button>
            <button className="inline-flex items-center gap-1 rounded border px-2 py-1 text-xs text-slate-600 hover:bg-slate-50" onClick={signOut}><LogOut className="h-3 w-3" />{t('common.signOut')}</button>
          </div>
        </div>
      </aside>
      <div className="min-w-0 flex-1">
        <div className="flex items-center justify-between border-b bg-white px-4 py-2 md:hidden">
          <span className="font-semibold">RMS</span>
          <button className="rounded border px-2 py-1 text-xs" onClick={() => i18n.changeLanguage(i18n.language === 'ar' ? 'en' : 'ar')}>{t('common.language')}</button>
        </div>
        <main className="mx-auto max-w-[1400px] p-4 md:p-6"><Outlet /></main>
      </div>
    </div>
  );
}
