import { Navigate, Route, Routes } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useAuth } from './lib/auth';
import Layout from './components/Layout';
import { Spinner } from './components/ui';
import Login from './pages/Login';
import SetPassword from './pages/SetPassword';
import Dashboard from './pages/Dashboard';
import Customers from './pages/Customers';
import CustomerDetail from './pages/CustomerDetail';
import Pipeline from './pages/Pipeline';
import OpportunityDetail from './pages/OpportunityDetail';
import QuotationDetail from './pages/QuotationDetail';
import Templates from './pages/Templates';
import Admin from './pages/Admin';
import { InvoiceDetail, Invoices } from './pages/Invoices';
import { Audit, Leads, Projects, Quotations, Suppliers, TenderDetail, Tenders } from './pages/Lists';
import { ExpenseDetail, Expenses } from './pages/Expenses';
import { PurchaseOrderDetail, PurchaseRequestDetail, Purchases } from './pages/Purchases';
import { CustomerPoDetail, CustomerPos } from './pages/CustomerPos';
import { SupplierInvoiceDetail, SupplierInvoices } from './pages/SupplierInvoices';
import ProjectDetail from './pages/ProjectDetail';
import Accounting from './pages/Accounting';
import PoCenter from './pages/PoCenter';

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
  const { me, loading, signedIn, needsPassword } = useAuth();
  if (loading) return <Spinner />;
  if (needsPassword && (me || signedIn)) return <SetPassword />;
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
        <Route path="expenses" element={<Guard perm={['expenses.read', 'expenses.write']}><Expenses /></Guard>} />
        <Route path="expenses/:id" element={<Guard perm={['expenses.read', 'expenses.write']}><ExpenseDetail /></Guard>} />
        <Route path="purchases" element={<Guard perm="procurement.read"><Purchases /></Guard>} />
        <Route path="purchases/orders/:id" element={<Guard perm="procurement.read"><PurchaseOrderDetail /></Guard>} />
        <Route path="purchases/requests/:id" element={<Guard perm="procurement.read"><PurchaseRequestDetail /></Guard>} />
        <Route path="po-center" element={<Guard perm={['customer_pos.read', 'procurement.read']}><PoCenter /></Guard>} />
        <Route path="customer-pos" element={<Guard perm="customer_pos.read"><CustomerPos /></Guard>} />
        <Route path="customer-pos/:id" element={<Guard perm="customer_pos.read"><CustomerPoDetail /></Guard>} />
        <Route path="supplier-invoices" element={<Guard perm={['procurement.read', 'invoices.read']}><SupplierInvoices /></Guard>} />
        <Route path="supplier-invoices/:id" element={<Guard perm={['procurement.read', 'invoices.read']}><SupplierInvoiceDetail /></Guard>} />
        <Route path="projects/:id" element={<Guard perm="projects.read"><ProjectDetail /></Guard>} />
        <Route path="accounting" element={<Guard perm="accounting.read"><Accounting /></Guard>} />
        <Route path="suppliers" element={<Guard perm="suppliers.read"><Suppliers /></Guard>} />
        <Route path="tenders" element={<Guard perm="tenders.read"><Tenders /></Guard>} />
        <Route path="tenders/:id" element={<Guard perm="tenders.read"><TenderDetail /></Guard>} />
        <Route path="quotations" element={<Guard perm="quotations.read"><Quotations /></Guard>} />
        <Route path="quotations/:id" element={<Guard perm="quotations.read"><QuotationDetail /></Guard>} />
        <Route path="templates" element={<Guard perm="estimation.read"><Templates /></Guard>} />
        <Route path="projects" element={<Guard perm={['projects.read', 'contracts.read', 'quotations.award']}><Projects /></Guard>} />
        <Route path="invoices" element={<Guard perm="invoices.read"><Invoices /></Guard>} />
        <Route path="invoices/:id" element={<Guard perm="invoices.read"><InvoiceDetail /></Guard>} />
        <Route path="admin" element={<Guard perm="users.manage"><Admin /></Guard>} />
        <Route path="audit" element={<Guard perm="audit.read"><Audit /></Guard>} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}
