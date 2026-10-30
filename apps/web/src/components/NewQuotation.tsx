import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useMutation, useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { api, qs } from '../lib/api';
import { useAuth } from '../lib/auth';
import { Button, ErrorBox, Field, Input, Modal, Select } from './ui';
import { CustomerSelect, useLookups } from './OpportunityForm';

const NEW_OPP = 'new';

// Started from an opportunity, or from the Quotations page, where the user picks the customer and either one of
// their open opportunities or a new one named after the quotation.
export default function NewQuotation({ open, onClose, opportunity }: { open: boolean; onClose: () => void; opportunity?: any }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const { can } = useAuth();
  const canOpen = can('crm.write'); // estimators quote on existing opportunities but cannot open new ones
  const { data: lk } = useLookups();
  const { data: templates = [] } = useQuery({ queryKey: ['quotation-templates'], queryFn: () => api.get('/quotation-templates'), enabled: open });
  const [customerId, setCustomerId] = useState('');
  const [oppId, setOppId] = useState('');
  const { data: opps = [] } = useQuery({
    queryKey: ['opportunities', 'for-quote', customerId],
    queryFn: () => api.get(`/opportunities${qs({ customer_id: customerId, limit: 200 })}`),
    enabled: open && !opportunity && !!customerId,
  });
  const openOpps = opps.filter((o: any) => o.stage !== 'won' && o.stage !== 'lost');
  const oppChoice = oppId || (canOpen ? NEW_OPP : openOpps[0]?.id ?? '');
  const { data: picked } = useQuery({
    queryKey: ['opportunity', oppChoice],
    queryFn: () => api.get(`/opportunities/${oppChoice}`),
    enabled: open && !opportunity && !!oppChoice && oppChoice !== NEW_OPP,
  });
  const opp = opportunity ?? picked;
  const [v, setV] = useState({ title: opportunity?.title ?? '', tender_id: opportunity?.tenders?.[0]?.id ?? '', template_id: '', currency: 'SAR' });

  const create = useMutation({
    mutationFn: async () => {
      if (!opportunity && !customerId) throw new Error(t('quote.pickCustomer'));
      let opportunityId = opportunity?.id ?? (oppChoice !== NEW_OPP ? oppChoice : null);
      if (!opportunityId) {
        if (!canOpen) throw new Error(t('quote.noOpportunity'));
        if (!v.title.trim()) throw new Error(t('quote.needTitle'));
        const o = await api.post('/opportunities', { title: v.title, customer_id: customerId, currency: v.currency });
        opportunityId = o.id;
      }
      return api.post('/quotations', { ...v, tender_id: v.tender_id || undefined, template_id: v.template_id || undefined, opportunity_id: opportunityId });
    },
    onSuccess: (q) => nav(`/quotations/${q.id}`),
  });

  return (
    <Modal open={open} onClose={onClose} title={t('quote.new')}
      footer={<><Button variant="secondary" onClick={onClose}>{t('common.cancel')}</Button><Button busy={create.isPending} onClick={() => create.mutate()}>{t('common.create')}</Button></>}>
      <ErrorBox error={create.error} />
      <div className="grid gap-3">
        {!opportunity && (<>
          <Field label={t('common.customer')}><CustomerSelect value={customerId} onChange={(x) => { setCustomerId(x); setOppId(''); setV({ ...v, tender_id: '' }); }} /></Field>
          {customerId && (
            <Field label={t('quote.opportunity')}><Select name="opportunity_id" value={oppChoice} onChange={(e) => {
              const id = e.target.value; setOppId(id);
              const o = openOpps.find((x: any) => x.id === id);
              setV({ ...v, tender_id: '', title: v.title || o?.title || '' });
            }}>
              {canOpen ? <option value={NEW_OPP}>{t('quote.newOpportunity')}</option> : !openOpps.length && <option value="">{t('quote.noOpportunity')}</option>}
              {openOpps.map((o: any) => <option key={o.id} value={o.id}>{o.number} — {o.title}</option>)}
            </Select></Field>
          )}
        </>)}
        <Field label={t('common.title')}><Input name="quote_title" value={v.title} onChange={(e) => setV({ ...v, title: e.target.value })} /></Field>
        {opp?.tenders?.length > 0 && (
          <Field label={t('nav.tenders')}><Select name="tender_id" value={v.tender_id} onChange={(e) => setV({ ...v, tender_id: e.target.value })}>
            <option value="">—</option>{opp.tenders.map((x: any) => <option key={x.id} value={x.id}>{x.number} — {x.title}</option>)}</Select></Field>
        )}
        <Field label={t('quote.template')}><Select name="template_id" value={v.template_id} onChange={(e) => setV({ ...v, template_id: e.target.value })}>
          <option value="">—</option>{templates.filter((x: any) => x.is_active).map((x: any) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <Field label={t('customer.currency')}><Select value={v.currency} onChange={(e) => setV({ ...v, currency: e.target.value })}>
          {lk?.currencies.map((c: any) => <option key={c.code} value={c.code}>{c.code}</option>)}</Select></Field>
      </div>
    </Modal>
  );
}
