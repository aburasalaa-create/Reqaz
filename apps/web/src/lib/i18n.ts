import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';

const en = {
  app: { name: 'Reqaz Management System', short: 'RMS' },
  nav: {
    dashboard: 'Dashboard', pipeline: 'Pipeline', leads: 'Leads', customers: 'Customers', suppliers: 'Suppliers',
    tenders: 'Tenders', quotations: 'Quotations', templates: 'Templates', projects: 'Contracts & projects',
    admin: 'Administration', audit: 'Audit log', sales: 'Sales', estimating: 'Estimating', delivery: 'Delivery', system: 'System',
  },
  common: {
    save: 'Save', cancel: 'Cancel', create: 'Create', edit: 'Edit', delete: 'Delete', add: 'Add', search: 'Search…',
    loading: 'Loading…', none: 'Nothing here yet', back: 'Back', close: 'Close', confirm: 'Confirm', yes: 'Yes', no: 'No',
    signOut: 'Sign out', language: 'العربية', actions: 'Actions', status: 'Status', name: 'Name', nameAr: 'Name (Arabic)',
    email: 'Email', phone: 'Phone', notes: 'Notes', customer: 'Customer', owner: 'Owner', created: 'Created', all: 'All',
    active: 'Active', inactive: 'Inactive', open: 'Open', details: 'Details', total: 'Total', value: 'Value', date: 'Date',
    upload: 'Upload', download: 'Download', attachments: 'Attachments', noPermission: 'You do not have access to this page.',
    saved: 'Saved', required: 'Required', optional: 'optional', comment: 'Comment', reason: 'Reason', view: 'View',
    title: 'Title', description: 'Description', type: 'Type', city: 'City', code: 'Code', number: 'No.', select: 'Select…',
  },
  login: {
    title: 'Sign in to RMS', email: 'Work email', password: 'Password', submit: 'Sign in', forgot: 'Forgot password?',
    resetSent: 'If the address is registered, a reset link has been sent.', devTitle: 'Development sign-in',
    devHint: 'Local development only: choose a seeded user.', inactive: 'Your account is not active in RMS. Ask an administrator for access.',
  },
  dashboard: {
    title: 'Executive dashboard', pipeline: 'Open pipeline', weighted: 'Weighted pipeline', deals: 'Open opportunities',
    winRate: 'Win rate (12 months)', deadlines: 'Upcoming tender deadlines', overdue: 'Overdue follow-ups',
    approvals: 'Quotations awaiting approval', wins: 'Recent wins', byStage: 'Pipeline by stage', daysLeft: '{{count}} days left', dueToday: 'Due today', overdueBy: 'Overdue',
  },
  stage: {
    new_lead: 'New lead', qualified: 'Qualified', tender_received: 'Tender received', estimation: 'Estimation',
    internal_review: 'Internal review', quotation_submitted: 'Quotation submitted', negotiation: 'Negotiation', won: 'Won', lost: 'Lost',
  },
  source: { website: 'Website', manual: 'Manual', email: 'Email', referral: 'Referral', phone: 'Phone', other: 'Other' },
  partyType: { company: 'Company', government: 'Government', individual: 'Individual' },
  tenderStatus: { received: 'Received', under_review: 'Under review', estimating: 'Estimating', submitted: 'Submitted', won: 'Won', lost: 'Lost', no_bid: 'No bid', cancelled: 'Cancelled' },
  revStatus: { draft: 'Draft', pending_approval: 'Pending approval', approved: 'Approved', submitted: 'Submitted to client', superseded: 'Superseded', awarded: 'Awarded' },
  proposal: {
    heading: 'Proposal content', cover: 'Cover page', title: 'Proposal title', projectName: 'Project name (cover subtitle)', location: 'Location',
    rfpRef: 'Client RFP reference', referencePrefix: 'Reference prefix', referenceHint: 'The revision is appended, e.g. ARS/RUH111026-01R00. Leave blank to use the quotation number.',
    priceDisplay: 'Price layout', itemised: 'Itemised (rate per line)', lumpSum: 'Lump sum per section with lettered sub-items',
    letter: 'Cover letter', cc: 'Cc', signatory: 'Signed by', signatoryHint: 'Name, phone and e-mail shown at the end of the letter.', preparer: 'The preparer',
    coverLetter: 'Cover letter body', summary: 'Summary & terms', executiveSummary: 'Executive summary', scopeList: 'Project scope (one item per line)',
    schedule: 'Delivery schedule', stage: 'Stage', description: 'Description', duration: 'Est. time', generalTerms: 'Terms (one per line)',
    delivery: 'Delivery & execution', warranty: 'Warranty', milestones: 'Payment milestones', milestonesMust100: 'Payment milestones must total 100% before submitting for approval.',
    compliance: 'Compliance matrix', ref: 'RFQ §', requirement: 'Requirement', complianceStatus: 'Compliance', addRow: 'Add row',
    internalHint: 'Never printed on the proposal.',
  },
  quoteStatus: { open: 'Open', won: 'Won', lost: 'Lost', cancelled: 'Cancelled' },
  followUpType: { call: 'Call', meeting: 'Meeting', email: 'Email', site_visit: 'Site visit', task: 'Task' },
  customer: {
    title: 'Customers', new: 'New customer', partyType: 'Type', vat: 'VAT number', cr: 'CR number', website: 'Website',
    address: 'National address', building: 'Building no.', street: 'Street', district: 'District', postal: 'Postal code',
    country: 'Country', terms: 'Payment terms (days)', currency: 'Currency', creditLimit: 'Credit limit', contacts: 'Contacts',
    newContact: 'Add contact', position: 'Position', primary: 'Primary', opportunities: 'Opportunities', quotations: 'Quotations', vatHint: '15 digits, starts and ends with 3',
  },
  supplier: { title: 'Suppliers', new: 'New supplier', category: 'Category', contact: 'Contact person' },
  opp: {
    title: 'Sales pipeline', new: 'New opportunity', prospect: 'Prospect (before a customer record exists)', company: 'Company',
    contact: 'Contact', service: 'Service', location: 'Location', expectedValue: 'Expected value', probability: 'Win probability %',
    closeDate: 'Expected close', source: 'Source', stage: 'Stage', lostReason: 'Lost reason', moveTo: 'Move to', history: 'Stage history',
    followUps: 'Follow-ups', newFollowUp: 'Add follow-up', due: 'Due', complete: 'Mark done', reopen: 'Reopen', outcome: 'Outcome',
    tenders: 'Tenders / RFQs', quotations: 'Quotations', linkCustomer: 'Link customer', nextFollowUp: 'Next follow-up', showClosed: 'Show closed',
    dragHint: 'Drag cards between columns to change stage.', wonByAward: 'Opportunities are marked won by awarding a quotation.',
    markLost: 'Mark lost',
  },
  lead: { title: 'Website & inbound leads', new: 'Record enquiry', convert: 'Convert to opportunity', reject: 'Reject', spam: 'Spam', service: 'Service of interest', message: 'Message', received: 'Received', company: 'Company', contact: 'Contact' },
  tender: {
    title: 'Tenders & RFQs', new: 'Record tender', clientRef: 'Client reference', issueDate: 'Issue date', deadline: 'Submission deadline',
    clarification: 'Clarification deadline', siteVisit: 'Site visit', bidBond: 'Bid bond required', bidBondAmount: 'Bid bond amount',
    upcoming: 'Upcoming only', opportunity: 'Opportunity',
  },
  quote: {
    title: 'Quotations', new: 'New quotation', revision: 'Revision', revisions: 'Revisions', newRevision: 'New revision',
    template: 'Terms template', boqTemplate: 'Insert BOQ template', lines: 'Bill of quantities', addLine: 'Add line',
    section: 'Section', item: 'Item', descEn: 'Description (English)', descAr: 'Description (Arabic)', unit: 'Unit', qty: 'Qty',
    material: 'Material', labour: 'Labour', equipment: 'Equipment', subcontract: 'Subcontract', other: 'Other',
    unitCost: 'Unit cost', costTotal: 'Cost', sellRate: 'Rate', sellTotal: 'Amount', pricing: 'Pricing',
    overhead: 'Overhead %', contingency: 'Contingency %', method: 'Pricing method', markup: 'Mark-up %', margin: 'Target margin %',
    methodMarkup: 'Mark-up on cost', methodMargin: 'Target profit margin', discount: 'Discount', discountType: 'Discount type',
    discountNone: 'None', discountPercent: 'Percent', discountAmount: 'Fixed amount', vat: 'VAT',
    directCost: 'Direct cost', overheadAmt: 'Overhead', contingencyAmt: 'Contingency', totalCost: 'Total cost',
    subtotal: 'Subtotal', net: 'Total excl. VAT', vatAmt: 'VAT', totalInclVat: 'Total incl. VAT', grossProfit: 'Gross profit',
    grossMargin: 'Gross margin', terms: 'Commercial terms', subject: 'Subject', validUntil: 'Valid until', attention: 'Attention',
    scope: 'Scope of work', exclusions: 'Exclusions', paymentTerms: 'Payment terms', completion: 'Completion period', internalNotes: 'Internal notes',
    english: 'English', arabic: 'Arabic', pdf: 'PDF', pdfBilingual: 'Bilingual PDF', pdfEn: 'English PDF', pdfAr: 'Arabic PDF',
    submitForApproval: 'Submit for approval', withdraw: 'Withdraw', approve: 'Approve', reject: 'Reject', markSubmitted: 'Record as sent to client',
    award: 'Award → contract & project', markLost: 'Mark lost', approvals: 'Approval history', locked: 'This revision is locked. Create a new revision to change it.',
    clientPdf: 'PDF sent to client', livePreview: 'Live estimate (saved figures are recalculated by the server)', costBreakdown: 'Cost breakdown',
    projectName: 'Project name', projectManager: 'Project manager', startDate: 'Start date', targetDate: 'Target completion', signedDate: 'Contract signed',
    retention: 'Retention %', advance: 'Advance payment %', awarded: 'Awarded', contract: 'Contract', project: 'Project', rejectComment: 'Reason for rejection',
    estimateOnly: 'Internal — never shown to the client',
  },
  tpl: { title: 'Templates', boq: 'BOQ templates', terms: 'Quotation terms templates', newBoq: 'New BOQ template', newTerms: 'New terms template', items: 'items' },
  project: { contracts: 'Contracts', projects: 'Projects', value: 'Contract value', budget: 'Approved budget', pm: 'Project manager', start: 'Start', target: 'Target completion', phase2: 'Schedules, documents, budgets and variations arrive in Phase 2.' },
  admin: {
    title: 'Administration', users: 'Users', roles: 'Roles', invite: 'Invite user', settings: 'Company settings', legalEn: 'Legal name (English)',
    legalAr: 'Legal name (Arabic)', addressEn: 'Address (English)', addressAr: 'Address (Arabic)', validity: 'Default quotation validity (days)',
    selfApproval: 'Allow preparers to approve their own quotations', deactivate: 'Deactivate', activate: 'Activate', permissions: 'Permissions',
  },
  audit: { title: 'Audit log', table: 'Table', record: 'Record', actor: 'User', action: 'Action', when: 'When', changes: 'Changes' },
};

const ar: typeof en = {
  app: { name: 'نظام ركاز للإدارة', short: 'RMS' },
  nav: {
    dashboard: 'لوحة القيادة', pipeline: 'مسار المبيعات', leads: 'العملاء المحتملون', customers: 'العملاء', suppliers: 'الموردون',
    tenders: 'المناقصات', quotations: 'عروض الأسعار', templates: 'القوالب', projects: 'العقود والمشاريع',
    admin: 'الإدارة', audit: 'سجل التدقيق', sales: 'المبيعات', estimating: 'التسعير', delivery: 'التنفيذ', system: 'النظام',
  },
  common: {
    save: 'حفظ', cancel: 'إلغاء', create: 'إنشاء', edit: 'تعديل', delete: 'حذف', add: 'إضافة', search: 'بحث…',
    loading: 'جارٍ التحميل…', none: 'لا توجد بيانات بعد', back: 'رجوع', close: 'إغلاق', confirm: 'تأكيد', yes: 'نعم', no: 'لا',
    signOut: 'تسجيل الخروج', language: 'English', actions: 'إجراءات', status: 'الحالة', name: 'الاسم', nameAr: 'الاسم (عربي)',
    email: 'البريد الإلكتروني', phone: 'الهاتف', notes: 'ملاحظات', customer: 'العميل', owner: 'المسؤول', created: 'تاريخ الإنشاء', all: 'الكل',
    active: 'نشط', inactive: 'غير نشط', open: 'فتح', details: 'التفاصيل', total: 'الإجمالي', value: 'القيمة', date: 'التاريخ',
    upload: 'رفع ملف', download: 'تنزيل', attachments: 'المرفقات', noPermission: 'ليست لديك صلاحية الوصول إلى هذه الصفحة.',
    saved: 'تم الحفظ', required: 'مطلوب', optional: 'اختياري', comment: 'تعليق', reason: 'السبب', view: 'عرض',
    title: 'العنوان', description: 'الوصف', type: 'النوع', city: 'المدينة', code: 'الرمز', number: 'الرقم', select: 'اختر…',
  },
  login: {
    title: 'تسجيل الدخول إلى النظام', email: 'البريد الإلكتروني للعمل', password: 'كلمة المرور', submit: 'دخول', forgot: 'نسيت كلمة المرور؟',
    resetSent: 'إذا كان البريد مسجلاً فقد أُرسل رابط إعادة التعيين.', devTitle: 'دخول بيئة التطوير',
    devHint: 'للتطوير المحلي فقط: اختر مستخدماً تجريبياً.', inactive: 'حسابك غير مفعّل في النظام. تواصل مع مسؤول النظام.',
  },
  dashboard: {
    title: 'لوحة القيادة التنفيذية', pipeline: 'قيمة الفرص المفتوحة', weighted: 'القيمة المرجحة', deals: 'الفرص المفتوحة',
    winRate: 'نسبة الفوز (12 شهراً)', deadlines: 'مواعيد تسليم المناقصات القادمة', overdue: 'متابعات متأخرة',
    approvals: 'عروض بانتظار الاعتماد', wins: 'أحدث الترسيات', byStage: 'المسار حسب المرحلة', daysLeft: 'متبقٍ {{count}} يوم', dueToday: 'مستحق اليوم', overdueBy: 'متأخر',
  },
  stage: {
    new_lead: 'عميل محتمل جديد', qualified: 'مؤهل', tender_received: 'استلام المناقصة', estimation: 'التسعير',
    internal_review: 'مراجعة داخلية', quotation_submitted: 'تم تقديم العرض', negotiation: 'تفاوض', won: 'فوز', lost: 'خسارة',
  },
  source: { website: 'الموقع الإلكتروني', manual: 'إدخال يدوي', email: 'بريد إلكتروني', referral: 'توصية', phone: 'هاتف', other: 'أخرى' },
  partyType: { company: 'شركة', government: 'جهة حكومية', individual: 'فرد' },
  tenderStatus: { received: 'مستلمة', under_review: 'قيد المراجعة', estimating: 'قيد التسعير', submitted: 'مقدمة', won: 'فوز', lost: 'خسارة', no_bid: 'عدم المشاركة', cancelled: 'ملغاة' },
  revStatus: { draft: 'مسودة', pending_approval: 'بانتظار الاعتماد', approved: 'معتمد', submitted: 'مُرسل للعميل', superseded: 'مستبدل', awarded: 'تمت الترسية' },
  proposal: {
    heading: 'محتوى العرض', cover: 'صفحة الغلاف', title: 'عنوان العرض', projectName: 'اسم المشروع (العنوان الفرعي)', location: 'الموقع',
    rfpRef: 'مرجع طلب العميل', referencePrefix: 'بادئة المرجع', referenceHint: 'يُضاف رقم المراجعة تلقائياً، مثل ARS/RUH111026-01R00. اتركه فارغاً لاستخدام رقم العرض.',
    priceDisplay: 'طريقة عرض الأسعار', itemised: 'تفصيلي (سعر لكل بند)', lumpSum: 'مبلغ مقطوع لكل قسم مع بنود فرعية',
    letter: 'خطاب التقديم', cc: 'نسخة إلى', signatory: 'الموقّع', signatoryHint: 'يظهر الاسم والهاتف والبريد في نهاية الخطاب.', preparer: 'مُعد العرض',
    coverLetter: 'نص خطاب التقديم', summary: 'الملخص والشروط', executiveSummary: 'الملخص التنفيذي', scopeList: 'نطاق المشروع (بند في كل سطر)',
    schedule: 'الجدول الزمني للتنفيذ', stage: 'المرحلة', description: 'الوصف', duration: 'المدة المقدرة', generalTerms: 'الشروط (شرط في كل سطر)',
    delivery: 'التسليم والتنفيذ', warranty: 'الضمان', milestones: 'دفعات السداد', milestonesMust100: 'يجب أن يكون مجموع دفعات السداد 100% قبل الإرسال للاعتماد.',
    compliance: 'مصفوفة الامتثال', ref: 'البند', requirement: 'المتطلب', complianceStatus: 'الامتثال', addRow: 'إضافة سطر',
    internalHint: 'لا تُطبع في العرض.',
  },
  quoteStatus: { open: 'مفتوح', won: 'فوز', lost: 'خسارة', cancelled: 'ملغى' },
  followUpType: { call: 'اتصال', meeting: 'اجتماع', email: 'بريد', site_visit: 'زيارة موقع', task: 'مهمة' },
  customer: {
    title: 'العملاء', new: 'عميل جديد', partyType: 'النوع', vat: 'الرقم الضريبي', cr: 'السجل التجاري', website: 'الموقع الإلكتروني',
    address: 'العنوان الوطني', building: 'رقم المبنى', street: 'الشارع', district: 'الحي', postal: 'الرمز البريدي',
    country: 'الدولة', terms: 'شروط الدفع (أيام)', currency: 'العملة', creditLimit: 'حد الائتمان', contacts: 'جهات الاتصال',
    newContact: 'إضافة جهة اتصال', position: 'المنصب', primary: 'رئيسي', opportunities: 'الفرص', quotations: 'عروض الأسعار', vatHint: '15 رقماً يبدأ وينتهي بالرقم 3',
  },
  supplier: { title: 'الموردون', new: 'مورد جديد', category: 'الفئة', contact: 'الشخص المسؤول' },
  opp: {
    title: 'مسار المبيعات', new: 'فرصة جديدة', prospect: 'بيانات العميل المحتمل (قبل إنشاء سجل عميل)', company: 'الشركة',
    contact: 'جهة الاتصال', service: 'الخدمة', location: 'الموقع', expectedValue: 'القيمة المتوقعة', probability: 'احتمال الفوز %',
    closeDate: 'تاريخ الإغلاق المتوقع', source: 'المصدر', stage: 'المرحلة', lostReason: 'سبب الخسارة', moveTo: 'نقل إلى', history: 'سجل المراحل',
    followUps: 'المتابعات', newFollowUp: 'إضافة متابعة', due: 'الاستحقاق', complete: 'تم', reopen: 'إعادة فتح', outcome: 'النتيجة',
    tenders: 'المناقصات وطلبات التسعير', quotations: 'عروض الأسعار', linkCustomer: 'ربط بعميل', nextFollowUp: 'المتابعة التالية', showClosed: 'إظهار المغلقة',
    dragHint: 'اسحب البطاقات بين الأعمدة لتغيير المرحلة.', wonByAward: 'يتم تسجيل الفوز عند ترسية عرض السعر.',
    markLost: 'تسجيل خسارة',
  },
  lead: { title: 'طلبات الموقع والطلبات الواردة', new: 'تسجيل طلب', convert: 'تحويل إلى فرصة', reject: 'رفض', spam: 'رسالة مزعجة', service: 'الخدمة المطلوبة', message: 'الرسالة', received: 'تاريخ الاستلام', company: 'الشركة', contact: 'جهة الاتصال' },
  tender: {
    title: 'المناقصات وطلبات التسعير', new: 'تسجيل مناقصة', clientRef: 'مرجع العميل', issueDate: 'تاريخ الإصدار', deadline: 'آخر موعد للتقديم',
    clarification: 'آخر موعد للاستفسارات', siteVisit: 'زيارة الموقع', bidBond: 'ضمان ابتدائي مطلوب', bidBondAmount: 'قيمة الضمان الابتدائي',
    upcoming: 'القادمة فقط', opportunity: 'الفرصة',
  },
  quote: {
    title: 'عروض الأسعار', new: 'عرض سعر جديد', revision: 'المراجعة', revisions: 'المراجعات', newRevision: 'مراجعة جديدة',
    template: 'قالب الشروط', boqTemplate: 'إدراج قالب جدول كميات', lines: 'جدول الكميات', addLine: 'إضافة بند',
    section: 'القسم', item: 'البند', descEn: 'الوصف (إنجليزي)', descAr: 'الوصف (عربي)', unit: 'الوحدة', qty: 'الكمية',
    material: 'مواد', labour: 'عمالة', equipment: 'معدات', subcontract: 'مقاول باطن', other: 'أخرى',
    unitCost: 'تكلفة الوحدة', costTotal: 'التكلفة', sellRate: 'سعر الوحدة', sellTotal: 'المبلغ', pricing: 'التسعير',
    overhead: 'المصاريف غير المباشرة %', contingency: 'الطوارئ %', method: 'طريقة التسعير', markup: 'نسبة الإضافة %', margin: 'هامش الربح المستهدف %',
    methodMarkup: 'إضافة على التكلفة', methodMargin: 'هامش ربح مستهدف', discount: 'الخصم', discountType: 'نوع الخصم',
    discountNone: 'بدون', discountPercent: 'نسبة', discountAmount: 'مبلغ ثابت', vat: 'ضريبة القيمة المضافة',
    directCost: 'التكلفة المباشرة', overheadAmt: 'غير مباشرة', contingencyAmt: 'الطوارئ', totalCost: 'إجمالي التكلفة',
    subtotal: 'المجموع', net: 'الإجمالي قبل الضريبة', vatAmt: 'الضريبة', totalInclVat: 'الإجمالي شامل الضريبة', grossProfit: 'إجمالي الربح',
    grossMargin: 'هامش الربح', terms: 'الشروط التجارية', subject: 'الموضوع', validUntil: 'صالح حتى', attention: 'عناية',
    scope: 'نطاق العمل', exclusions: 'الاستثناءات', paymentTerms: 'شروط الدفع', completion: 'مدة التنفيذ', internalNotes: 'ملاحظات داخلية',
    english: 'إنجليزي', arabic: 'عربي', pdf: 'PDF', pdfBilingual: 'PDF ثنائي اللغة', pdfEn: 'PDF إنجليزي', pdfAr: 'PDF عربي',
    submitForApproval: 'إرسال للاعتماد', withdraw: 'سحب', approve: 'اعتماد', reject: 'رفض', markSubmitted: 'تسجيل الإرسال للعميل',
    award: 'ترسية ← عقد ومشروع', markLost: 'تسجيل خسارة', approvals: 'سجل الاعتماد', locked: 'هذه المراجعة مقفلة. أنشئ مراجعة جديدة لتعديلها.',
    clientPdf: 'نسخة PDF المرسلة للعميل', livePreview: 'تقدير مباشر (يعيد الخادم احتساب الأرقام المحفوظة)', costBreakdown: 'تفصيل التكاليف',
    projectName: 'اسم المشروع', projectManager: 'مدير المشروع', startDate: 'تاريخ البدء', targetDate: 'تاريخ الإنجاز المستهدف', signedDate: 'تاريخ توقيع العقد',
    retention: 'المحتجزات %', advance: 'الدفعة المقدمة %', awarded: 'تمت الترسية', contract: 'العقد', project: 'المشروع', rejectComment: 'سبب الرفض',
    estimateOnly: 'داخلي — لا يظهر للعميل',
  },
  tpl: { title: 'القوالب', boq: 'قوالب جداول الكميات', terms: 'قوالب شروط العروض', newBoq: 'قالب جدول كميات جديد', newTerms: 'قالب شروط جديد', items: 'بنود' },
  project: { contracts: 'العقود', projects: 'المشاريع', value: 'قيمة العقد', budget: 'الميزانية المعتمدة', pm: 'مدير المشروع', start: 'البدء', target: 'الإنجاز المستهدف', phase2: 'الجداول الزمنية والوثائق والميزانيات والأوامر التغييرية في المرحلة الثانية.' },
  admin: {
    title: 'الإدارة', users: 'المستخدمون', roles: 'الأدوار', invite: 'دعوة مستخدم', settings: 'إعدادات الشركة', legalEn: 'الاسم القانوني (إنجليزي)',
    legalAr: 'الاسم القانوني (عربي)', addressEn: 'العنوان (إنجليزي)', addressAr: 'العنوان (عربي)', validity: 'مدة صلاحية العرض الافتراضية (أيام)',
    selfApproval: 'السماح لمُعد العرض باعتماده بنفسه', deactivate: 'إيقاف', activate: 'تفعيل', permissions: 'الصلاحيات',
  },
  audit: { title: 'سجل التدقيق', table: 'الجدول', record: 'السجل', actor: 'المستخدم', action: 'الإجراء', when: 'الوقت', changes: 'التغييرات' },
};

const saved = (() => { try { return localStorage.getItem('rms.lang'); } catch { return null; } })();

void i18n.use(initReactI18next).init({
  resources: { en: { translation: en }, ar: { translation: ar } },
  lng: saved === 'ar' ? 'ar' : 'en',
  fallbackLng: 'en',
  interpolation: { escapeValue: false },
});

export function applyDirection(lng: string) {
  document.documentElement.lang = lng;
  document.documentElement.dir = lng === 'ar' ? 'rtl' : 'ltr';
}
applyDirection(i18n.language);
i18n.on('languageChanged', (lng) => {
  applyDirection(lng);
  try { localStorage.setItem('rms.lang', lng); } catch { /* storage unavailable */ }
});

export default i18n;
