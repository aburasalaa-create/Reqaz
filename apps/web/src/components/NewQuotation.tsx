import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useMutation, useQuery } from '@tanstack/react-query';
import { useTranslation } from 'react-i18next';
import { api } from '../lib/api';
import { Button, ErrorBox, Field, Input, Modal, Select } from './ui';
import { useLookups } from './OpportunityForm';

export default function NewQuotation({ open, onClose, opportunity }: { open: boolean; onClose: () => void; opportunity: any }) {
  const { t } = useTranslation();
  const nav = useNavigate();
  const { data: lk } = useLookups();
  const { data: templates = [] } = useQuery({ queryKey: ['quotation-templates'], queryFn: () => api.get('/quotation-templates'), enabled: open });
  const [v, setV] = useState({ title: opportunity.title, tender_id: opportunity.tenders?.[0]?.id ?? '', template_id: '', currency: 'SAR' });
  const create = useMutation({
    mutationFn: () => api.post('/quotations', { ...v, opportunity_id: opportunity.id }),
    onSuccess: (q) => nav(`/quotations/${q.id}`),
  });
  return (
    <Modal open={open} onClose={onClose} title={t('quote.new')}
      footer={<><Button variant="secondary" onClick={onClose}>{t('common.cancel')}</Button><Button busy={create.isPending} onClick={() => create.mutate()}>{t('common.create')}</Button></>}>
      <ErrorBox error={create.error} />
      <div className="grid gap-3">
        <Field label={t('common.title')}><Input name="quote_title" value={v.title} onChange={(e) => setV({ ...v, title: e.target.value })} /></Field>
        <Field label={t('nav.tenders')}><Select name="tender_id" value={v.tender_id} onChange={(e) => setV({ ...v, tender_id: e.target.value })}>
          <option value="">—</option>{opportunity.tenders?.map((x: any) => <option key={x.id} value={x.id}>{x.number} — {x.title}</option>)}</Select></Field>
        <Field label={t('quote.template')}><Select name="template_id" value={v.template_id} onChange={(e) => setV({ ...v, template_id: e.target.value })}>
          <option value="">—</option>{templates.filter((x: any) => x.is_active).map((x: any) => <option key={x.id} value={x.id}>{x.name}</option>)}</Select></Field>
        <Field label={t('customer.currency')}><Select value={v.currency} onChange={(e) => setV({ ...v, currency: e.target.value })}>
          {lk?.currencies.map((c: any) => <option key={c.code} value={c.code}>{c.code}</option>)}</Select></Field>
      </div>
    </Modal>
  );
}
