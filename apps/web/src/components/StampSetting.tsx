import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { api, fetchBlobUrl } from '../lib/api';
import { Button, useToast } from './ui';

/** Upload, preview and remove the company stamp printed on issued invoices. */
export default function StampSetting() {
  const { t } = useTranslation();
  const toast = useToast();
  const [url, setUrl] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const load = () => fetchBlobUrl('/admin/brand-assets/stamp').then(setUrl).catch(() => setUrl(null));
  useEffect(() => { void load(); }, []);

  const upload = async (f: File | undefined) => {
    if (!f) return;
    const fd = new FormData();
    fd.append('file', f);
    setBusy(true);
    try { await api.put('/admin/brand-assets/stamp', fd); await load(); toast(t('common.saved')); }
    catch (e) { toast((e as Error).message, 'error'); } finally { setBusy(false); }
  };
  const remove = async () => { await api.del('/admin/brand-assets/stamp'); setUrl(null); };

  return (
    <div className="sm:col-span-2">
      <div className="label">{t('admin.stamp')}</div>
      <div className="flex items-center gap-4 rounded-md border p-3">
        {url ? <img src={url} alt="" className="h-24 w-24 object-contain" data-testid="stamp-preview" /> : <div className="text-sm text-slate-500">{t('admin.noStamp')}</div>}
        <div className="flex flex-col gap-2">
          <label className="inline-flex cursor-pointer items-center rounded-md border px-3 py-1.5 text-sm hover:bg-slate-50">
            {busy ? '…' : t('admin.uploadStamp')}
            <input type="file" accept="image/png,image/jpeg" className="hidden" data-testid="stamp-file" onChange={(e) => upload(e.target.files?.[0])} />
          </label>
          {url && <Button variant="ghost" onClick={remove}>{t('common.delete')}</Button>}
          <p className="max-w-sm text-xs text-slate-500">{t('admin.stampHint')}</p>
        </div>
      </div>
    </div>
  );
}
