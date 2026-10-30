import { useRef, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Download, Paperclip, Trash2 } from 'lucide-react';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { dateTime } from '../lib/format';
import { Button, Card, Empty, useToast } from './ui';

export default function Attachments({ entityType, entityId, canWrite }: { entityType: string; entityId: string; canWrite: boolean }) {
  const { t } = useTranslation();
  const { me } = useAuth();
  const toast = useToast();
  const qc = useQueryClient();
  const input = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const key = ['attachments', entityType, entityId];
  const { data = [] } = useQuery({ queryKey: key, queryFn: () => api.get(`/attachments${qs({ entity_type: entityType, entity_id: entityId })}`), enabled: me?.files_enabled !== false });
  const del = useMutation({
    mutationFn: (id: string) => api.del(`/attachments/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: key }),
    onError: (e: Error) => toast(e.message, 'error'),
  });

  const upload = async (files: FileList | null) => {
    if (!files?.length) return;
    setBusy(true);
    try {
      for (const f of Array.from(files)) {
        const fd = new FormData();
        fd.set('entity_type', entityType);
        fd.set('entity_id', entityId);
        fd.set('file', f);
        await api.upload('/attachments', fd);
      }
      await qc.invalidateQueries({ queryKey: key });
    } catch (e: any) { toast(e.message, 'error'); } finally {
      setBusy(false);
      if (input.current) input.current.value = '';
    }
  };

  // File storage switched off on this server: nothing to show or upload.
  if (me?.files_enabled === false) return null;
  return (
    <Card title={<span className="inline-flex items-center gap-1"><Paperclip className="h-4 w-4" />{t('common.attachments')}</span>} bodyClass="p-0"
      actions={canWrite && (<>
        <input ref={input} type="file" multiple className="hidden" data-testid={`upload-${entityType}`} onChange={(e) => upload(e.target.files)} />
        <Button variant="secondary" busy={busy} onClick={() => input.current?.click()}>{t('common.upload')}</Button>
      </>)}>
      {data.length ? (
        <ul className="divide-y">
          {data.map((a: any) => (
            <li key={a.id} className="flex items-center justify-between gap-2 px-4 py-2 text-sm">
              <span className="min-w-0"><span className="block truncate">{a.file_name}</span>
                <span className="text-xs text-slate-400">{(a.size_bytes / 1024).toFixed(0)} KB · {a.uploaded_by_name} · {dateTime(a.created_at)}</span></span>
              <span className="flex shrink-0 gap-1">
                <Button variant="ghost" aria-label={t('common.download')} onClick={() => api.openFile(`/attachments/${a.id}/download`, a.file_name).catch((e) => toast(e.message, 'error'))}><Download className="h-4 w-4" /></Button>
                {canWrite && !a.is_system_generated && <Button variant="ghost" aria-label={t('common.delete')} onClick={() => confirm(`${t('common.delete')} ${a.file_name}?`) && del.mutate(a.id)}><Trash2 className="h-4 w-4" /></Button>}
              </span>
            </li>
          ))}
        </ul>
      ) : <Empty />}
    </Card>
  );
}
