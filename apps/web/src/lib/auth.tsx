import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { api, setTokenProvider } from './api';

export const AUTH_MODE = (import.meta.env.VITE_AUTH_MODE ?? 'supabase') as 'supabase' | 'dev';

// Supabase URL and public key. The API's runtime values (/api/public-config) win, so fixing them needs only a
// restart; values compiled in at build time (VITE_SUPABASE_*) are the fallback.
let publicConfig: { supabaseUrl?: string | null; supabaseAnonKey?: string | null } = {
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL, supabaseAnonKey: import.meta.env.VITE_SUPABASE_ANON_KEY,
};

/** Call once before rendering. Throws with a readable message if sign-in cannot be configured. */
export async function loadPublicConfig() {
  if (AUTH_MODE !== 'supabase') return;
  const res = await fetch((import.meta.env.VITE_API_URL ?? '') + '/api/public-config').catch(() => null);
  if (res?.ok) {
    const remote = await res.json();
    publicConfig = { supabaseUrl: remote.supabaseUrl || publicConfig.supabaseUrl, supabaseAnonKey: remote.supabaseAnonKey || publicConfig.supabaseAnonKey };
  } else if (!publicConfig.supabaseUrl || !publicConfig.supabaseAnonKey) {
    throw new Error(`The server did not return its sign-in settings (HTTP ${res?.status ?? 'no response'}).`);
  }
  getSupabase();
}

let supabase: SupabaseClient | null = null;
export function getSupabase() {
  if (!supabase) {
    const url = publicConfig.supabaseUrl?.trim();
    const key = publicConfig.supabaseAnonKey?.trim();
    if (!url || !key) throw new Error('Sign-in is not configured: set SUPABASE_URL and SUPABASE_ANON_KEY (or VITE_SUPABASE_ANON_KEY) on the server.');
    try {
      supabase = createClient(url, key, { auth: { persistSession: true, autoRefreshToken: true } });
    } catch (e: any) {
      throw new Error(`Sign-in settings are invalid (Supabase URL "${url}"): ${e?.message ?? e}`);
    }
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
