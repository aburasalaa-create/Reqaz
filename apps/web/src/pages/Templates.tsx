import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { Plus, Trash2 } from 'lucide-react';
import { api } from '../lib/api';
import { useAuth } from '../lib/auth';
import { Badge, Button, Card, Empty, ErrorBox, Field, Input, Modal, PageHeader, Select, Textarea } from '../components/ui';

const ITEM_COLS = ['section', 'item_code', 'description_en', 'description_ar', 'unit', 'quantity', 'material_unit_cost', 'labour_unit_cost', 'equipment_unit_cost', 'subcontract_unit_cost', 'other_unit_cost'] as const;
const ITEM_LABEL: Record<string, string> = { section: 'quote.section', item_code: 'quote.item', description_en: 'quote.descEn', description_ar: 'quote.descAr', unit: 'quote.unit', quantity: 'quote.qty',
  material_unit_cost: 'quote.material', labour_unit_cost: 'quote.labour', equipment_unit_cost: 'quote.equipment', subcontract_unit_cost: 'quote.subcontract', other_unit_cost: 'quote.other' };

export default function Templates() {
  const { t } = useTranslation();
  const { can } = useAuth();
  const qc = useQueryClient();
  const w = can('estimation.write');
  const boqs = useQuery({ queryKey: ['boq-templates'], queryFn: () => api.get('/boq-templates') });
  const terms = useQuery({ queryKey: ['quotation-templates'], queryFn: () => api.get('/quotation-templates') });
  const [boq, setBoq] = useState<any>(null);
  const [term, setTerm] = useState<any>(null);

  const openBoq = async (id?: string) => setBoq(id ? await api.get(`/boq-templates/${id}`) : { name: '', description: '', is_active: true, items: [] });
  const saveBoq = useMutation({
    mutationFn: () => {
      const body = { name: boq.name, description: boq.description ?? '', is_active: boq.is_active,
        items: boq.items.map((i: any) => Object.fromEntries(ITEM_COLS.map((c) => [c, i[c] === null || i[c] === undefined ? (c.endsWith('cost') ? '0' : c === 'quantity' ? '1' : '') : String(i[c])]))) };
      return boq.id ? api.put(`/boq-templates/${boq.id}`, body) : api.post('/boq-templates', body);
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['boq-templates'] }); setBoq(null); },
  });
  const saveTerm = useMutation({
    mutationFn: () => {
      const { id, created_at, updated_at, ...body } = term;
      return id ? api.patch(`/quotation-templates/${id}`, body) : api.post('/quotation-templates', body);
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['quotation-templates'] }); setTerm(null); },
  });
  const setItem = (i: number, k: string, v: string) => setBoq((b: any) => ({ ...b, items: b.items.map((x: any, j: number) => (j === i ? { ...x, [k]: v } : x)) }));

  return (
    <div className="space-y-4">
      <PageHeader title={t('tpl.title')} />
      <Card title={t('tpl.boq')} bodyClass="p-0" actions={w && <Button variant="secondary" onClick={() => openBoq()}><Plus className="h-4 w-4" />{t('tpl.newBoq')}</Button>}>
        {boqs.data?.length ? <ul className="divide-y">{boqs.data.map((b: any) => (
          <li key={b.id} className="flex items-center justify-between px-4 py-2 text-sm"><button className="link" onClick={() => openBoq(b.id)}>{b.name}</button>
            <span className="text-slate-500">{b.item_count} {t('tpl.items')} {!b.is_active && <Badge>{t('common.inactive')}</Badge>}</span></li>))}</ul> : <Empty />}
      </Card>
      <Card title={t('tpl.terms')} bodyClass="p-0" actions={w && <Button variant="secondary" onClick={() => setTerm({ name: '', pricing_method: 'markup', overhead_pct: '10', contingency_pct: '5', markup_pct: '15', target_margin_pct: '15', is_active: true })}><Plus className="h-4 w-4" />{t('tpl.newTerms')}</Button>}>
        {terms.data?.length ? <ul className="divide-y">{terms.data.map((x: any) => (
          <li key={x.id} className="flex items-center justify-between px-4 py-2 text-sm"><button className="link" onClick={() => setTerm(x)}>{x.name}</button>
            <span className="text-xs text-slate-500">OH {Number(x.overhead_pct)}% · C {Number(x.contingency_pct)}% · {x.pricing_method === 'markup' ? `MU ${Number(x.markup_pct)}%` : `GM ${Number(x.target_margin_pct)}%`}</span></li>))}</ul> : <Empty />}
      </Card>

      <Modal open={!!boq} onClose={() => setBoq(null)} title={boq?.name || t('tpl.newBoq')} wide
        footer={w && <><Button variant="secondary" onClick={() => setBoq(null)}>{t('common.cancel')}</Button><Button busy={saveBoq.isPending} onClick={() => saveBoq.mutate()}>{t('common.save')}</Button></>}>
        <ErrorBox error={saveBoq.error} />
        {boq && <fieldset disabled={!w} className="space-y-3">
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label={t('common.name')}><Input value={boq.name} onChange={(e) => setBoq({ ...boq, name: e.target.value })} /></Field>
            <label className="flex items-center gap-2 self-end pb-2 text-sm"><input type="checkbox" checked={boq.is_active} onChange={(e) => setBoq({ ...boq, is_active: e.target.checked })} />{t('common.active')}</label>
            <Field label={t('common.description')} className="sm:col-span-2"><Input value={boq.description ?? ''} onChange={(e) => setBoq({ ...boq, description: e.target.value })} /></Field>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full min-w-[1000px] text-xs">
              <thead><tr>{ITEM_COLS.map((c) => <th key={c} className="th">{t(ITEM_LABEL[c])}</th>)}<th /></tr></thead>
              <tbody>{boq.items.map((it: any, i: number) => (
                <tr key={i}>{ITEM_COLS.map((c) => <td key={c} className="p-0.5"><input className="input px-1 py-0.5 text-xs" dir={c === 'description_ar' ? 'rtl' : undefined} value={it[c] ?? ''} onChange={(e) => setItem(i, c, e.target.value)} /></td>)}
                  <td><button aria-label={t('common.delete')} className="p-1 text-slate-400 hover:text-red-600" onClick={() => setBoq({ ...boq, items: boq.items.filter((_: any, j: number) => j !== i) })}><Trash2 className="h-4 w-4" /></button></td></tr>
              ))}</tbody>
            </table>
          </div>
          <Button variant="secondary" onClick={() => setBoq({ ...boq, items: [...boq.items, { unit: 'm3', quantity: '1', section: boq.items.at(-1)?.section ?? '' }] })}><Plus className="h-4 w-4" />{t('quote.addLine')}</Button>
        </fieldset>}
      </Modal>

      <Modal open={!!term} onClose={() => setTerm(null)} title={term?.name || t('tpl.newTerms')} wide
        footer={w && <><Button variant="secondary" onClick={() => setTerm(null)}>{t('common.cancel')}</Button><Button busy={saveTerm.isPending} onClick={() => saveTerm.mutate()}>{t('common.save')}</Button></>}>
        <ErrorBox error={saveTerm.error} />
        {term && <fieldset disabled={!w} className="grid gap-3 sm:grid-cols-2">
          <Field label={t('common.name')} className="sm:col-span-2"><Input value={term.name} onChange={(e) => setTerm({ ...term, name: e.target.value })} /></Field>
          <Field label={t('quote.overhead')}><Input type="number" value={term.overhead_pct} onChange={(e) => setTerm({ ...term, overhead_pct: e.target.value })} /></Field>
          <Field label={t('quote.contingency')}><Input type="number" value={term.contingency_pct} onChange={(e) => setTerm({ ...term, contingency_pct: e.target.value })} /></Field>
          <Field label={t('quote.method')}><Select value={term.pricing_method} onChange={(e) => setTerm({ ...term, pricing_method: e.target.value })}><option value="markup">{t('quote.methodMarkup')}</option><option value="margin">{t('quote.methodMargin')}</option></Select></Field>
          {term.pricing_method === 'markup' ? <Field label={t('quote.markup')}><Input type="number" value={term.markup_pct} onChange={(e) => setTerm({ ...term, markup_pct: e.target.value })} /></Field>
            : <Field label={t('quote.margin')}><Input type="number" value={term.target_margin_pct} onChange={(e) => setTerm({ ...term, target_margin_pct: e.target.value })} /></Field>}
          {(['scope', 'exclusions', 'payment_terms', 'completion_period'] as const).flatMap((k) => (['en', 'ar'] as const).map((l) => (
            <Field key={`${k}_${l}`} label={`${t(`quote.${k === 'payment_terms' ? 'paymentTerms' : k === 'completion_period' ? 'completion' : k}`)} — ${t(l === 'en' ? 'quote.english' : 'quote.arabic')}`}>
              <Textarea dir={l === 'ar' ? 'rtl' : undefined} value={term[`${k}_${l}`] ?? ''} onChange={(e) => setTerm({ ...term, [`${k}_${l}`]: e.target.value })} /></Field>)))}
        </fieldset>}
      </Modal>
    </div>
  );
}
