export const OPPORTUNITY_STAGES = [
  'new_lead', 'qualified', 'tender_received', 'estimation', 'internal_review',
  'quotation_submitted', 'negotiation', 'won', 'lost',
] as const;
export type OpportunityStage = (typeof OPPORTUNITY_STAGES)[number];

export const LEAD_SOURCES = ['website', 'manual', 'email', 'referral', 'phone', 'other'] as const;
export type LeadSource = (typeof LEAD_SOURCES)[number];

export const TENDER_STATUSES = ['received', 'under_review', 'estimating', 'submitted', 'won', 'lost', 'no_bid', 'cancelled'] as const;
export type TenderStatus = (typeof TENDER_STATUSES)[number];

export const REVISION_STATUSES = ['draft', 'pending_approval', 'approved', 'submitted', 'superseded', 'awarded'] as const;
export type RevisionStatus = (typeof REVISION_STATUSES)[number];

export const QUOTATION_STATUSES = ['open', 'won', 'lost', 'cancelled'] as const;
export type QuotationStatus = (typeof QUOTATION_STATUSES)[number];

export const FOLLOW_UP_TYPES = ['call', 'meeting', 'email', 'site_visit', 'task'] as const;
export type FollowUpType = (typeof FOLLOW_UP_TYPES)[number];

export const PARTY_TYPES = ['company', 'government', 'individual'] as const;

export const COST_CATEGORIES = ['material', 'labour', 'equipment', 'subcontract', 'other'] as const;
export type CostCategory = (typeof COST_CATEGORIES)[number];

export const PERMISSIONS = [
  'dashboard.read', 'customers.read', 'customers.write', 'suppliers.read', 'suppliers.write',
  'crm.read', 'crm.write', 'tenders.read', 'tenders.write', 'estimation.read', 'estimation.write',
  'quotations.read', 'quotations.write', 'quotations.approve', 'quotations.submit', 'quotations.award',
  'contracts.read', 'projects.read', 'settings.manage', 'users.manage', 'audit.read',
  'invoices.read', 'invoices.write', 'invoices.issue', 'payments.write',
  'procurement.read', 'procurement.request', 'procurement.approve', 'procurement.order',
] as const;
export type Permission = (typeof PERMISSIONS)[number];

/** Saudi VAT registration number: 15 digits, starts and ends with 3. */
export const isValidSaudiVatNumber = (v: string) => /^3\d{13}3$/.test(v);
