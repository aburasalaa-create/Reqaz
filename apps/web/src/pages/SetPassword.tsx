import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useAuth } from '../lib/auth';
import { Button, ErrorBox, Field, Input } from '../components/ui';
import { AuthScreen } from '../components/Brand';

// Shown after an invite or password-reset link signs the user in, before any other page.
export default function SetPassword() {
  const { t } = useTranslation();
  const { setPassword, signOut } = useAuth();
  const [password, setValue] = useState('');
  const [confirm, setConfirm] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (password.length < 8) return setError(new Error(t('login.tooShort')));
    if (password !== confirm) return setError(new Error(t('login.mismatch')));
    setBusy(true); setError(null);
    try { await setPassword(password); } catch (err) { setError(err); } finally { setBusy(false); }
  };

  return (
    <AuthScreen>
      <form onSubmit={submit} className="space-y-3">
        <div>
          <div className="text-lg font-medium text-ink">{t('login.setTitle')}</div>
          <div className="text-sm text-slate-500">{t('login.setHint')}</div>
        </div>
        <ErrorBox error={error} />
        <Field label={t('login.newPassword')}><Input type="password" autoComplete="new-password" required value={password} onChange={(e) => setValue(e.target.value)} /></Field>
        <Field label={t('login.confirmPassword')}><Input type="password" autoComplete="new-password" required value={confirm} onChange={(e) => setConfirm(e.target.value)} /></Field>
        <div className="flex items-center justify-between">
          <button type="button" className="link text-sm" onClick={() => void signOut()}>{t('login.cancel')}</button>
          <Button type="submit" busy={busy}>{t('login.savePassword')}</Button>
        </div>
      </form>
    </AuthScreen>
  );
}
