import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AUTH_MODE, getSupabase, useAuth } from '../lib/auth';
import { api } from '../lib/api';
import { Button, ErrorBox, Field, Input } from '../components/ui';

export default function Login() {
  const { t, i18n } = useTranslation();
  const { signInWithPassword, devSignIn, error: authError, signedIn } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [info, setInfo] = useState('');
  const [devUsers, setDevUsers] = useState<{ email: string; full_name: string; roles: string[] }[]>([]);

  useEffect(() => {
    if (AUTH_MODE === 'dev') api.get('/dev/users').then(setDevUsers).catch(setError);
  }, []);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    try { await signInWithPassword(email, password); } catch (err) { setError(err); } finally { setBusy(false); }
  };
  const reset = async () => {
    if (!email) return;
    await getSupabase().auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}/reset-password` });
    setInfo(t('login.resetSent'));
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-gradient-to-br from-brand-900 to-brand-700 p-4">
      <div className="w-full max-w-md rounded-xl bg-white p-6 shadow-2xl">
        <div className="mb-5 flex items-center justify-between">
          <div>
            <div className="text-lg font-semibold text-brand-800">{i18n.language === 'ar' ? 'ركاز المتحدة للمقاولات' : 'Reqaz United Contracting'}</div>
            <div className="text-sm text-slate-500">{t('login.title')}</div>
          </div>
          <button className="rounded border px-2 py-1 text-xs" onClick={() => i18n.changeLanguage(i18n.language === 'ar' ? 'en' : 'ar')}>{t('common.language')}</button>
        </div>
        {signedIn && <div className="mb-3"><ErrorBox error={new Error(t('login.inactive'))} /></div>}
        {authError && !signedIn && <div className="mb-3"><ErrorBox error={new Error(authError)} /></div>}
        <ErrorBox error={error} />
        {AUTH_MODE === 'dev' ? (
          <div>
            <h2 className="mb-1 mt-2 text-sm font-semibold">{t('login.devTitle')}</h2>
            <p className="mb-3 text-xs text-slate-500">{t('login.devHint')}</p>
            <div className="grid gap-2">
              {devUsers.map((u) => (
                <button key={u.email} data-testid={`dev-login-${u.email}`} onClick={() => devSignIn(u.email).catch(setError)}
                  className="flex items-center justify-between rounded-md border px-3 py-2 text-start text-sm hover:border-brand-500 hover:bg-brand-50">
                  <span><span className="font-medium">{u.full_name}</span><span className="block text-xs text-slate-500">{u.email}</span></span>
                  <span className="text-xs text-slate-500">{u.roles.join(', ')}</span>
                </button>
              ))}
            </div>
          </div>
        ) : (
          <form onSubmit={submit} className="space-y-3">
            <Field label={t('login.email')}><Input type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
            <Field label={t('login.password')}><Input type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} /></Field>
            {info && <div className="text-sm text-emerald-700">{info}</div>}
            <div className="flex items-center justify-between">
              <button type="button" className="link text-sm" onClick={reset}>{t('login.forgot')}</button>
              <Button type="submit" busy={busy}>{t('login.submit')}</Button>
            </div>
          </form>
        )}
      </div>
    </div>
  );
}
