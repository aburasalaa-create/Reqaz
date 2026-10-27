import { Navigate, Route, Routes } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useAuth } from './lib/auth';
import Layout from './components/Layout';
import { Spinner } from './components/ui';
import Login from './pages/Login';
import Dashboard from './pages/Dashboard';
import Customers from './pages/Customers';
import CustomerDetail from './pages/CustomerDetail';
import Pipeline from './pages/Pipeline';
import OpportunityDetail from './pages/OpportunityDetail';
import QuotationDetail from './pages/QuotationDetail';
import Templates from './pages/Templates';
import Admin from './pages/Admin';
import { Audit, Leads, Projects, Quotations, Suppliers, TenderDetail, Tenders } from './pages/Lists';

function Guard({ perm, children }: { perm: string | string[]; children: React.ReactNode }) {
  const { can } = useAuth();
  const { t } = useTranslation();
  const ok = Array.isArray(perm) ? perm.some(can) : can(perm);
  return ok ? <>{children}</> : <div className="card p-6 text-sm text-slate-600">{t('common.noPermission')}</div>;
}

function Home() {
  const { can } = useAuth();
  if (can('dashboard.read')) return <Dashboard />;
  if (can('projects.read')) return <Navigate to="/projects" replace />;
  return <Navigate to="/customers" replace />;
}

export default function App() {
  const { me, loading } = useAuth();
  if (loading) return <Spinner />;
  if (!me) return <Login />;
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Home />} />
        <Route path="pipeline" element={<Guard perm="crm.read"><Pipeline /></Guard>} />
        <Route path="opportunities/:id" element={<Guard perm="crm.read"><OpportunityDetail /></Guard>} />
        <Route path="leads" element={<Guard perm="crm.read"><Leads /></Guard>} />
        <Route path="customers" element={<Guard perm="customers.read"><Customers /></Guard>} />
        <Route path="customers/:id" element={<Guard perm="customers.read"><CustomerDetail /></Guard>} />
        <Route path="suppliers" element={<Guard perm="suppliers.read"><Suppliers /></Guard>} />
        <Route path="tenders" element={<Guard perm="tenders.read"><Tenders /></Guard>} />
        <Route path="tenders/:id" element={<Guard perm="tenders.read"><TenderDetail /></Guard>} />
        <Route path="quotations" element={<Guard perm="quotations.read"><Quotations /></Guard>} />
        <Route path="quotations/:id" element={<Guard perm="quotations.read"><QuotationDetail /></Guard>} />
        <Route path="templates" element={<Guard perm="estimation.read"><Templates /></Guard>} />
        <Route path="projects" element={<Guard perm={['projects.read', 'contracts.read', 'quotations.award']}><Projects /></Guard>} />
        <Route path="admin" element={<Guard perm="users.manage"><Admin /></Guard>} />
        <Route path="audit" element={<Guard perm="audit.read"><Audit /></Guard>} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}
