import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { api, setTokenProvider } from './api';

export const AUTH_MODE = (import.meta.env.VITE_AUTH_MODE ?? 'supabase') as 'supabase' | 'dev';

let supabase: SupabaseClient | null = null;
export function getSupabase() {
  if (!supabase) {
    const url = import.meta.env.VITE_SUPABASE_URL;
    const key = import.meta.env.VITE_SUPABASE_ANON_KEY;
    if (!url || !key) throw new Error('VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY must be set');
    supabase = createClient(url, key, { auth: { persistSession: true, autoRefreshToken: true } });
  }
  return supabase;
}

export interface Me {
  id: string;
  email: string;
  full_name: string;
  full_name_ar: string | null;
  locale: 'en' | 'ar';
  permissions: string[];
  roles: { code: string; name_en: string; name_ar: string }[];
}

interface AuthState {
  me: Me | null;
  loading: boolean;
  error: string | null;
  signedIn: boolean;
  can: (perm: string) => boolean;
  signInWithPassword: (email: string, password: string) => Promise<void>;
  devSignIn: (email: string) => Promise<void>;
  signOut: () => Promise<void>;
  refresh: () => Promise<void>;
}

const Ctx = createContext<AuthState | null>(null);
const DEV_KEY = 'rms.devToken';

export function AuthProvider({ children }: { children: ReactNode }) {
  const [me, setMe] = useState<Me | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [signedIn, setSignedIn] = useState(false);

  useEffect(() => {
    setTokenProvider(async () => {
      if (AUTH_MODE === 'dev') return sessionStorage.getItem(DEV_KEY);
      const { data } = await getSupabase().auth.getSession();
      return data.session?.access_token ?? null;
    });
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      setMe(await api.get<Me>('/me'));
      setError(null);
      setSignedIn(true);
    } catch (e: any) {
      setMe(null);
      setSignedIn(e?.status === 403);
      setError(e?.status === 401 ? null : e?.message ?? 'Error');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (AUTH_MODE === 'dev') {
      if (sessionStorage.getItem(DEV_KEY)) void refresh(); else setLoading(false);
      return;
    }
    const sb = getSupabase();
    sb.auth.getSession().then(({ data }) => (data.session ? refresh() : setLoading(false)));
    const { data: sub } = sb.auth.onAuthStateChange((event) => {
      if (event === 'SIGNED_OUT') { setMe(null); setSignedIn(false); }
      if (event === 'SIGNED_IN') void refresh();
    });
    return () => sub.subscription.unsubscribe();
  }, [refresh]);

  const value = useMemo<AuthState>(() => ({
    me, loading, error, signedIn,
    can: (p) => !!me?.permissions.includes(p),
    async signInWithPassword(email, password) {
      const { error: err } = await getSupabase().auth.signInWithPassword({ email, password });
      if (err) throw err;
      await refresh();
    },
    async devSignIn(email) {
      sessionStorage.removeItem(DEV_KEY);
      const r = await api.post<{ access_token: string }>('/dev/login', { email });
      sessionStorage.setItem(DEV_KEY, r.access_token);
      await refresh();
    },
    async signOut() {
      if (AUTH_MODE === 'dev') sessionStorage.removeItem(DEV_KEY);
      else await getSupabase().auth.signOut();
      setMe(null);
      setSignedIn(false);
    },
    refresh,
  }), [me, loading, error, signedIn, refresh]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useAuth() {
  const v = useContext(Ctx);
  if (!v) throw new Error('useAuth outside AuthProvider');
  return v;
}
