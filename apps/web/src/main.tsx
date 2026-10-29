import { Component, StrictMode, type ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import '@fontsource/jost/300.css';
import '@fontsource/jost/400.css';
import '@fontsource/jost/500.css';
import '@fontsource/jost/600.css';
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

// Plain message instead of a blank page when the app cannot start or crashes; i18n and auth may not be ready.
function StartError({ message }: { message: string }) {
  return (
    <div className="mx-auto mt-24 max-w-lg rounded-lg border bg-white p-6 text-sm text-slate-700" role="alert">
      <h1 className="mb-2 text-base font-semibold">RMS could not start</h1>
      <p className="break-words">{message}</p>
    </div>
  );
}

class CrashGuard extends Component<{ children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  render() { return this.state.error ? <StartError message={this.state.error.message} /> : this.props.children; }
}

const root = createRoot(document.getElementById('root')!);

loadPublicConfig().then(() => root.render(
  <StrictMode><CrashGuard>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <AuthProvider>
          <ToastProvider><App /></ToastProvider>
        </AuthProvider>
      </BrowserRouter>
    </QueryClientProvider>
  </CrashGuard></StrictMode>,
), (e: Error) => root.render(<StartError message={e.message} />));
