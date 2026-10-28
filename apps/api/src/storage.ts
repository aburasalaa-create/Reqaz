import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { Config } from './config.js';

/** Private object storage for business documents. Files are never publicly addressable. */
export interface Storage {
  put(key: string, body: Buffer, contentType: string): Promise<void>;
  get(key: string): Promise<Buffer>;
}

export function createStorage(cfg: Config): Storage {
  if (cfg.STORAGE_DRIVER === 'supabase') {
    if (!cfg.SUPABASE_URL || !cfg.SUPABASE_SERVICE_ROLE_KEY) throw new Error('Supabase storage needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY');
    return supabaseStorage(cfg.SUPABASE_URL, cfg.SUPABASE_SERVICE_ROLE_KEY, cfg.STORAGE_BUCKET);
  }
  return localStorage(path.resolve(cfg.STORAGE_LOCAL_DIR));
}

function localStorage(root: string): Storage {
  const resolve = (key: string) => {
    const p = path.resolve(root, key);
    if (!p.startsWith(root + path.sep)) throw new Error('Invalid storage key');
    return p;
  };
  return {
    async put(key, body) {
      const p = resolve(key);
      await mkdir(path.dirname(p), { recursive: true });
      await writeFile(p, body, { flag: 'wx' });
    },
    async get(key) {
      return readFile(resolve(key));
    },
  };
}

// Supabase Storage REST API, authenticated with the service-role key (server side only).
function supabaseStorage(url: string, serviceKey: string, bucket: string): Storage {
  const base = new URL('/storage/v1/object/', url).toString();
  const headers = supabaseKeyHeaders(serviceKey);
  return {
    async put(key, body, contentType) {
      const res = await fetch(`${base}${bucket}/${key}`, {
        method: 'POST',
        headers: { ...headers, 'Content-Type': contentType, 'x-upsert': 'false' },
        body: new Uint8Array(body),
      });
      if (!res.ok) throw new Error(`Storage upload failed: ${res.status} ${await res.text()}`);
    },
    async get(key) {
      const res = await fetch(`${base}authenticated/${bucket}/${key}`, { headers });
      if (!res.ok) throw new Error(`Storage download failed: ${res.status}`);
      return Buffer.from(await res.arrayBuffer());
    },
  };
}

export function newStorageKey(entityType: string, entityId: string, fileName: string) {
  const ext = path.extname(fileName).toLowerCase().replace(/[^a-z0-9.]/g, '').slice(0, 10);
  const now = new Date();
  return `${entityType}/${entityId}/${now.getUTCFullYear()}/${randomUUID()}${ext}`;
}

export const sha256 = (b: Buffer) => createHash('sha256').update(b).digest('hex');

/** New-style secret keys (sb_secret_…) are sent as `apikey` only; legacy service-role JWTs also as a Bearer token. */
export function supabaseKeyHeaders(key: string): Record<string, string> {
  return key.startsWith('sb_') ? { apikey: key } : { apikey: key, Authorization: `Bearer ${key}` };
}
