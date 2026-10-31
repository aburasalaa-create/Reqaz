import { useEffect, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Plus } from 'lucide-react';
import { api } from '../lib/api';
import { useAuth } from '../lib/auth';
import { pick } from '../lib/format';
import { Badge, Button, Card, ErrorBox, Field, Input, Modal, PageHeader, Spinner, useToast } from '../components/ui';
import StampSetting from '../components/StampSetting';

export default function Admin() {
  const { t } = useTranslation();
  const toast = useToast();
  const qc = useQueryClient();
  const users = useQuery({ queryKey: ['admin-users'], queryFn: () => api.get('/admin/users') });
  const roles = useQuery({ queryKey: ['admin-roles'], queryFn: () => api.get('/admin/roles') });
  const lookups = useQuery({ queryKey: ['lookups'], queryFn: () => api.get('/lookups') });
  const [settings, setSettings] = useState<any>(null);
  const [invite, setInvite] = useState<any>(null);
  const [editRoles, setEditRoles] = useState<any>(null);
  useEffect(() => { if (lookups.data) setSettings(lookups.data.settings); }, [lookups.data]);
  const refresh = () => qc.invalidateQueries({ queryKey: ['admin-users'] });
  const onErr = (e: Error) => toast(e.message, 'error');

  const saveRoles = useMutation({ mutationFn: () => api.put(`/admin/users/${editRoles.id}/roles`, { roles: editRoles.roles }), onSuccess: () => { refresh(); setEditRoles(null); }, onError: onErr });
  const toggle = useMutation({ mutationFn: (u: any) => api.patch(`/admin/users/${u.id}`, { is_active: !u.is_active }), onSuccess: refresh, onError: onErr });
  const doInvite = useMutation({ mutationFn: () => api.post('/admin/users', invite), onSuccess: () => { refresh(); setInvite(null); } });
  const { refresh: reloadMe } = useAuth();
  const saveSettings = useMutation({
    mutationFn: () => api.patch('/admin/settings', {
      legal_name_en: settings.legal_name_en, legal_name_ar: settings.legal_name_ar, vat_number: settings.vat_number ?? '', cr_number: settings.cr_number ?? '',
      address_en: settings.address_en ?? '', address_ar: settings.address_ar ?? '', phone: settings.phone ?? '', email: settings.email ?? '', website: settings.website ?? '',
      ...Object.fromEntries(['unified_number','building_number','street','district','city','postal_code','additional_number','invoice_terms_en','invoice_terms_ar'].map((k) => [k, settings[k] ?? ''])),
      bank_accounts: (settings.bank_accounts ?? []).filter((b: any) => b.bank_name || b.iban),
      quotation_validity_days: Number(settings.quotation_validity_days), allow_self_approval: !!settings.allow_self_approval, open_access: !!settings.open_access, segregation_of_duties: !!settings.segregation_of_duties,
    }),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['lookups'] }); toast(t('common.saved')); void reloadMe(); }, onError: onErr,
  });

  if (users.isLoading || roles.isLoading) return <Spinner />;
  if (users.error) return <ErrorBox error={users.error} />;
  const roleName = (code: string) => { const r = roles.data.find((x: any) => x.code === code); return r ? pick(r.name_en, r.name_ar) : code; };

  return (
    <div className="space-y-4">
      <PageHeader title={t('admin.title')} />
      <Card title={t('admin.users')} bodyClass="p-0" actions={<Button variant="secondary" onClick={() => setInvite({ email: '', full_name: '', roles: [] })}><Plus className="h-4 w-4" />{t('admin.invite')}</Button>}>
        <table className="w-full"><thead className="bg-slate-50"><tr><th className="th">{t('common.name')}</th><th className="th">{t('common.email')}</th><th className="th">{t('admin.roles')}</th><th className="th">{t('common.status')}</th><th className="th" /></tr></thead>
          <tbody className="divide-y">{users.data.map((u: any) => (
            <tr key={u.id}><td className="td">{u.full_name}</td><td className="td">{u.email}</td>
              <td className="td"><div className="flex flex-wrap gap-1">{u.roles.map((r: string) => <Badge key={r} tone="blue">{roleName(r)}</Badge>)}</div></td>
              <td className="td">{u.is_active ? <Badge tone="green">{t('common.active')}</Badge> : <Badge tone="red">{t('common.inactive')}</Badge>}</td>
              <td className="td whitespace-nowrap"><Button variant="ghost" onClick={() => setEditRoles({ id: u.id, name: u.full_name, roles: u.roles })}>{t('admin.roles')}</Button>
                <Button variant="ghost" onClick={() => toggle.mutate(u)}>{u.is_active ? t('admin.deactivate') : t('admin.activate')}</Button></td></tr>
          ))}</tbody></table>
      </Card>
      <Card title={t('admin.roles')} bodyClass="p-0">
        <ul className="divide-y">{roles.data.map((r: any) => (
          <li key={r.id} className="px-4 py-2 text-sm"><span className="font-medium">{pick(r.name_en, r.name_ar)}</span>
            <div className="mt-1 flex flex-wrap gap-1">{r.permissions.map((p: string) => <span key={p} className="rounded bg-slate-100 px-1.5 py-0.5 font-mono text-[11px] text-slate-600">{p}</span>)}</div></li>
        ))}</ul>
      </Card>
      {settings && <Card title={t('admin.settings')} actions={<Button busy={saveSettings.isPending} onClick={() => saveSettings.mutate()}>{t('common.save')}</Button>}>
        <div className="grid gap-3 sm:grid-cols-2">
          {([['legal_name_en', 'admin.legalEn'], ['legal_name_ar', 'admin.legalAr'], ['vat_number', 'customer.vat'], ['cr_number', 'customer.cr'], ['address_en', 'admin.addressEn'], ['address_ar', 'admin.addressAr'],
            ['phone', 'common.phone'], ['email', 'common.email'], ['website', 'customer.website'], ['quotation_validity_days', 'admin.validity'],
            ['unified_number', 'admin.unified'], ['building_number', 'admin.building'], ['street', 'admin.street'], ['district', 'admin.district'], ['city', 'admin.city'],
            ['postal_code', 'admin.postal'], ['additional_number', 'admin.additional'],
            ['invoice_terms_en', 'admin.invTermsEn'], ['invoice_terms_ar', 'admin.invTermsAr']] as const).map(([k, l]) => (
            <Field key={k} label={t(l)}><Input dir={k.endsWith('_ar') ? 'rtl' : undefined} value={settings[k] ?? ''} onChange={(e) => setSettings({ ...settings, [k]: e.target.value })} /></Field>
          ))}
          <div className="sm:col-span-2">
            <div className="label">{t('admin.banks')}</div>
            {(settings.bank_accounts ?? []).map((b: any, i: number) => {
              const set = (k: string, v: unknown) => setSettings({ ...settings, bank_accounts: settings.bank_accounts.map((x: any, j: number) => (j === i ? { ...x, [k]: v } : x)) });
              return (
                <div key={i} className="mb-2 grid gap-2 rounded-md border p-2 sm:grid-cols-[1fr_1.4fr_1fr_auto_auto]">
                  <Input placeholder={t('admin.bank')} value={b.bank_name ?? ''} onChange={(e) => set('bank_name', e.target.value)} />
                  <Input placeholder={t('admin.iban')} value={b.iban ?? ''} onChange={(e) => set('iban', e.target.value.replace(/\s+/g, ''))} />
                  <Input placeholder={t('admin.accountNo')} value={b.account_number ?? ''} onChange={(e) => set('account_number', e.target.value)} />
                  <label className="flex items-center gap-1 text-xs"><input type="checkbox" checked={b.show_on_invoices !== false} onChange={(e) => set('show_on_invoices', e.target.checked)} />{t('admin.onInvoices')}</label>
                  <Button variant="ghost" onClick={() => setSettings({ ...settings, bank_accounts: settings.bank_accounts.filter((_: any, j: number) => j !== i) })}>{t('common.delete')}</Button>
                </div>
              );
            })}
            <Button variant="secondary" onClick={() => setSettings({ ...settings, bank_accounts: [...(settings.bank_accounts ?? []), { bank_name: '', iban: '', show_on_invoices: true }] })}>{t('admin.addBank')}</Button>
          </div>
          <StampSetting />
          <label className="flex items-center gap-2 text-sm sm:col-span-2"><input type="checkbox" checked={!!settings.open_access} onChange={(e) => setSettings({ ...settings, open_access: e.target.checked })} />{t('admin.openAccess')}</label>
          <label className="flex items-center gap-2 text-sm sm:col-span-2"><input type="checkbox" checked={!!settings.allow_self_approval} onChange={(e) => setSettings({ ...settings, allow_self_approval: e.target.checked })} />{t('admin.selfApproval')}</label>
          <label className="flex items-center gap-2 text-sm sm:col-span-2"><input type="checkbox" name="segregation_of_duties" checked={!!settings.segregation_of_duties} onChange={(e) => setSettings({ ...settings, segregation_of_duties: e.target.checked })} />{t('fin.segregation')}</label>
        </div>
      </Card>}
      <ApprovalLevels roles={roles.data} />
      <Modal open={!!editRoles} onClose={() => setEditRoles(null)} title={`${t('admin.roles')} — ${editRoles?.name ?? ''}`}
        footer={<><Button variant="secondary" onClick={() => setEditRoles(null)}>{t('common.cancel')}</Button><Button busy={saveRoles.isPending} onClick={() => saveRoles.mutate()}>{t('common.save')}</Button></>}>
        {editRoles && <div className="grid gap-2">{roles.data.map((r: any) => (
          <label key={r.code} className="flex items-center gap-2 text-sm"><input type="checkbox" checked={editRoles.roles.includes(r.code)}
            onChange={(e) => setEditRoles({ ...editRoles, roles: e.target.checked ? [...editRoles.roles, r.code] : editRoles.roles.filter((x: string) => x !== r.code) })} />{pick(r.name_en, r.name_ar)}</label>
        ))}</div>}
      </Modal>
      <Modal open={!!invite} onClose={() => setInvite(null)} title={t('admin.invite')}
        footer={<><Button variant="secondary" onClick={() => setInvite(null)}>{t('common.cancel')}</Button><Button busy={doInvite.isPending} onClick={() => doInvite.mutate()}>{t('admin.invite')}</Button></>}>
        <ErrorBox error={doInvite.error} />
        {invite && <div className="grid gap-3">
          <Field label={t('common.name')}><Input value={invite.full_name} onChange={(e) => setInvite({ ...invite, full_name: e.target.value })} /></Field>
          <Field label={t('common.email')}><Input type="email" value={invite.email} onChange={(e) => setInvite({ ...invite, email: e.target.value })} /></Field>
          <div className="grid gap-1">{roles.data.map((r: any) => (
            <label key={r.code} className="flex items-center gap-2 text-sm"><input type="checkbox" checked={invite.roles.includes(r.code)}
              onChange={(e) => setInvite({ ...invite, roles: e.target.checked ? [...invite.roles, r.code] : invite.roles.filter((x: string) => x !== r.code) })} />{pick(r.name_en, r.name_ar)}</label>
          ))}</div>
        </div>}
      </Modal>
    </div>
  );
}

const DOC_TYPES = ['purchase_order', 'purchase_request', 'customer_po', 'budget_change', 'variation', 'supplier_invoice'] as const;

/** Value-based approval levels per document type. No levels means one approval by anyone with the approve permission. */
function ApprovalLevels({ roles }: { roles: any[] }) {
  const { t } = useTranslation();
  const toast = useToast();
  const qc = useQueryClient();
  const { data } = useQuery({ queryKey: ['approval-levels'], queryFn: () => api.get('/approval-levels') });
  const [edit, setEdit] = useState<{ doc: string; levels: { min_amount: string; role_id: string }[] } | null>(null);
  const save = useMutation({
    mutationFn: () => api.put(`/approval-levels/${edit!.doc}`, edit!.levels.filter((l) => l.min_amount !== '').map((l) => ({ min_amount: l.min_amount, role_id: l.role_id || null }))),
    onSuccess: () => { setEdit(null); qc.invalidateQueries({ queryKey: ['approval-levels'] }); toast(t('common.saved')); },
    onError: (e: Error) => toast(e.message, 'error'),
  });
  return (
    <Card title={t('fin.approvalLevels')} bodyClass="p-0">
      <p className="px-4 pt-3 text-xs text-slate-500">{t('fin.approvalLevelsHint')}</p>
      <table className="w-full text-sm"><tbody className="divide-y">
        {DOC_TYPES.map((d) => {
          const lv = (data ?? []).filter((l: any) => l.doc_type === d);
          return (
            <tr key={d}><td className="td font-medium">{t(`fin.doc.${d}`)}</td>
              <td className="td text-xs">{lv.length ? lv.map((l: any) => `${t('fin.level')} ${l.level}: ${l.role_name ?? t('fin.anyApprover')} ${t('fin.from')} ${Number(l.min_amount).toLocaleString('en-US')}`).join(' · ') : t('fin.oneApproval')}</td>
              <td className="td text-end"><Button variant="ghost" data-testid={`levels-${d}`} onClick={() => setEdit({ doc: d, levels: lv.map((l: any) => ({ min_amount: String(Number(l.min_amount)), role_id: l.role_id ?? '' })) })}>{t('common.edit')}</Button></td></tr>
          );
        })}
      </tbody></table>
      <Modal open={!!edit} onClose={() => setEdit(null)} title={edit ? t(`fin.doc.${edit.doc}`) : ''}
        footer={<Button busy={save.isPending} onClick={() => save.mutate()} data-testid="levels-save">{t('common.save')}</Button>}>
        {edit && <div className="grid gap-2">
          {edit.levels.map((l, i) => (
            <div key={i} className="grid grid-cols-[1fr_1.4fr_auto] items-end gap-2">
              <Field label={t('fin.fromAmount')}><Input name={`level_amount_${i}`} type="number" value={l.min_amount} onChange={(e) => setEdit({ ...edit, levels: edit.levels.map((x, j) => (j === i ? { ...x, min_amount: e.target.value } : x)) })} /></Field>
              <Field label={t('fin.approverRole')}><select className="input" name={`level_role_${i}`} value={l.role_id} onChange={(e) => setEdit({ ...edit, levels: edit.levels.map((x, j) => (j === i ? { ...x, role_id: e.target.value } : x)) })}>
                <option value="">{t('fin.anyApprover')}</option>{roles.map((r: any) => <option key={r.id} value={r.id}>{pick(r.name_en, r.name_ar)}</option>)}</select></Field>
              <Button variant="ghost" onClick={() => setEdit({ ...edit, levels: edit.levels.filter((_, j) => j !== i) })}>{t('common.delete')}</Button>
            </div>
          ))}
          <Button variant="secondary" onClick={() => setEdit({ ...edit, levels: [...edit.levels, { min_amount: edit.levels.length ? '' : '0', role_id: '' }] })} data-testid="levels-add"><Plus className="h-4 w-4" />{t('fin.addLevel')}</Button>
          <p className="text-xs text-slate-500">{t('fin.levelsHint')}</p>
        </div>}
      </Modal>
    </Card>
  );
}
