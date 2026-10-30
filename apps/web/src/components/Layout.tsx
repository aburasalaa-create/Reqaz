import { NavLink, Outlet, useLocation } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { BarChart3, Briefcase, Building2, ClipboardList, FileText, Inbox, Receipt, KanbanSquare, LayoutTemplate, LogOut, Settings, ShieldCheck, ShoppingCart, Truck, Wallet } from 'lucide-react';
import { useAuth } from '../lib/auth';
import { pick } from '../lib/format';
import { cx } from './ui';
import { BrandLockup } from './Brand';

export default function Layout() {
  const { t, i18n } = useTranslation();
  const { me, can, signOut } = useAuth();
  const location = useLocation();
  // A short main menu for daily work; the rest sits under "More".
  const main = [
    { to: '/', icon: BarChart3, label: t('nav.dashboard'), perm: 'dashboard.read', end: true },
    { to: '/customers', icon: Building2, label: t('nav.customers'), perm: 'customers.read' },
    { to: '/pipeline', icon: KanbanSquare, label: t('nav.pipeline'), perm: 'crm.read' },
    { to: '/quotations', icon: FileText, label: t('nav.quotations'), perm: 'quotations.read' },
    { to: '/projects', icon: Briefcase, label: t('nav.projects'), perm: ['contracts.read', 'projects.read', 'quotations.award'] },
    { to: '/invoices', icon: Receipt, label: t('nav.invoices'), perm: 'invoices.read' },
    { to: '/expenses', icon: Wallet, label: t('nav.expenses'), perm: ['expenses.read', 'expenses.write'] },
    { to: '/purchases', icon: ShoppingCart, label: t('nav.purchases'), perm: 'procurement.read' },
    { to: '/admin', icon: Settings, label: t('nav.admin'), perm: 'users.manage' },
  ];
  const more = [
    { to: '/leads', icon: Inbox, label: t('nav.leads'), perm: 'crm.read' },
    { to: '/tenders', icon: ClipboardList, label: t('nav.tenders'), perm: 'tenders.read' },
    { to: '/suppliers', icon: Truck, label: t('nav.suppliers'), perm: 'suppliers.read' },
    { to: '/templates', icon: LayoutTemplate, label: t('nav.templates'), perm: 'estimation.read' },
    { to: '/audit', icon: ShieldCheck, label: t('nav.audit'), perm: 'audit.read' },
  ];
  const allowed = (p: string | string[]) => (Array.isArray(p) ? p.some(can) : can(p));

  return (
    <div className="flex min-h-screen">
      <aside className="sticky top-0 hidden h-screen w-60 shrink-0 flex-col border-e border-slate-200 bg-white md:flex">
        <div className="border-b border-sand px-4 py-3"><BrandLockup subtitle={t('app.name')} /></div>
        <nav className="flex-1 overflow-y-auto px-2 py-3">
          {main.filter((i) => allowed(i.perm)).map((i) => <NavItem key={i.to} {...i} />)}
          {more.some((i) => allowed(i.perm)) && (
            <details className="mt-3" open={more.some((i) => location.pathname.startsWith(i.to))}>
              <summary className="cursor-pointer px-2 pb-1 text-[11px] font-semibold uppercase tracking-wider text-slate-400">{t('nav.more')}</summary>
              {more.filter((i) => allowed(i.perm)).map((i) => <NavItem key={i.to} {...i} />)}
            </details>
          )}
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
        <div className="border-b bg-white md:hidden">
          <div className="flex items-center justify-between px-4 py-2">
            <span className="text-sm font-medium tracking-[0.45em] text-ink">REQAZ</span>
            <div className="flex gap-2">
              <button className="rounded border px-2 py-1 text-xs" onClick={() => i18n.changeLanguage(i18n.language === 'ar' ? 'en' : 'ar')}>{t('common.language')}</button>
              <button className="rounded border px-2 py-1 text-xs" onClick={signOut}>{t('common.signOut')}</button>
            </div>
          </div>
          <nav className="flex gap-1 overflow-x-auto px-2 pb-2">
            {[...main, ...more].filter((i) => allowed(i.perm)).map((i) => (
              <NavLink key={i.to} to={i.to} end={'end' in i} className={({ isActive }) => cx('flex shrink-0 items-center gap-1 rounded-md px-2 py-1 text-xs',
                isActive ? 'bg-brand-50 font-medium text-brand-800' : 'text-slate-600')}><i.icon className="h-3.5 w-3.5" />{i.label}</NavLink>
            ))}
          </nav>
        </div>
        <main className="mx-auto max-w-[1400px] p-4 md:p-6"><Outlet /></main>
      </div>
    </div>
  );
}

function NavItem({ to, icon: Icon, label, end }: { to: string; icon: typeof BarChart3; label: string; end?: boolean }) {
  return (
    <NavLink to={to} end={end} className={({ isActive }) => cx('flex items-center gap-2 rounded-md px-2 py-1.5 text-sm',
      isActive ? 'bg-brand-50 font-medium text-brand-800' : 'text-slate-600 hover:bg-slate-50')}>
      <Icon className="h-4 w-4" />{label}
    </NavLink>
  );
}
