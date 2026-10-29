import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import '@fontsource/noto-sans/400.css';
import '@fontsource/noto-sans/600.css';
import '@fontsource/noto-sans-arabic/400.css';
import '@fontsource/noto-sans-arabic/600.css';
import './index.css';
import './lib/i18n';
import { AuthProvider, loadPublicConfig } from './lib/auth';
import { ToastProvider } from './components/ui';
import App from './App';

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: (n, e: any) => n < 2 && !(e?.status >= 400 && e?.status < 500), refetchOnWindowFocus: false } },
});

const root = createRoot(document.getElementById('root')!);

loadPublicConfig().then(() => root.render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <AuthProvider>
          <ToastProvider><App /></ToastProvider>
        </AuthProvider>
      </BrowserRouter>
    </QueryClientProvider>
  </StrictMode>,
), (e: Error) => root.render(
  // Shown instead of a blank page when the app cannot start; plain markup because i18n and auth are not ready.
  <div className="mx-auto mt-24 max-w-lg rounded-lg border bg-white p-6 text-sm text-slate-700" role="alert">
    <h1 className="mb-2 text-base font-semibold">RMS could not start</h1>
    <p>{e.message}</p>
  </div>,
));
