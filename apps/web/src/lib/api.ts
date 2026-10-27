const BASE = (import.meta.env.VITE_API_URL ?? '') + '/api';

let tokenProvider: () => Promise<string | null> = async () => null;
export const setTokenProvider = (fn: () => Promise<string | null>) => { tokenProvider = fn; };

export class ApiError extends Error {
  constructor(public status: number, message: string, public code?: string, public issues?: { path: (string | number)[]; message: string }[]) {
    super(message);
  }
}

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const token = await tokenProvider();
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  let payload: BodyInit | undefined;
  if (body instanceof FormData) payload = body;
  else if (body !== undefined) { headers['Content-Type'] = 'application/json'; payload = JSON.stringify(body); }
  const res = await fetch(BASE + path, { method, headers, body: payload });
  if (res.status === 204) return undefined as T;
  const data = res.headers.get('content-type')?.includes('json') ? await res.json() : null;
  if (!res.ok) {
    const issues = data?.issues?.map((i: any) => ({ path: i.path, message: i.message }));
    const msg = issues?.length ? issues.map((i: any) => `${i.path.join('.')}: ${i.message}`).join('; ') : data?.message ?? res.statusText;
    throw new ApiError(res.status, msg, data?.error, issues);
  }
  return data as T;
}

export const api = {
  get: <T = any>(p: string) => request<T>('GET', p),
  post: <T = any>(p: string, b?: unknown) => request<T>('POST', p, b ?? {}),
  patch: <T = any>(p: string, b: unknown) => request<T>('PATCH', p, b),
  put: <T = any>(p: string, b: unknown) => request<T>('PUT', p, b),
  del: <T = any>(p: string) => request<T>('DELETE', p),
  upload: <T = any>(p: string, f: FormData) => request<T>('POST', p, f),
  /** Fetch a protected file (PDF, attachment) and open or save it. */
  async openFile(path: string, fileName?: string) {
    const token = await tokenProvider();
    const res = await fetch(BASE + path, { headers: token ? { Authorization: `Bearer ${token}` } : {} });
    if (!res.ok) throw new ApiError(res.status, (await res.json().catch(() => null))?.message ?? res.statusText);
    const url = URL.createObjectURL(await res.blob());
    const a = document.createElement('a');
    a.href = url;
    if (fileName) a.download = fileName; else a.target = '_blank';
    a.rel = 'noopener';
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
  },
};

export const qs = (o: Record<string, string | number | boolean | undefined | null>) => {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(o)) if (v !== undefined && v !== null && v !== '') p.set(k, String(v));
  const s = p.toString();
  return s ? `?${s}` : '';
};
