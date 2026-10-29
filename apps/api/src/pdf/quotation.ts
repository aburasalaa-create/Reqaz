// Client proposal PDF, modelled on Reqaz's own proposal format:
//   1. Cover page   2. Cover letter (optional)   3. Summary & terms   4. Compliance matrix (optional)
//   5. Financial proposal (itemised, or lump sum per main item with lettered sub-items)
// Shows selling prices only — never cost build-up, overhead, contingency or margin.
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { amountInWords } from '@rms/shared';

export type PdfLanguage = 'bilingual' | 'en' | 'ar';

const require = createRequire(import.meta.url);
const font = (pkg: string, file: string) => readFileSync(require.resolve(`${pkg}/files/${file}`)).toString('base64');
export const LOGO = `data:image/png;base64,${readFileSync(new URL('../../assets/reqaz-logo.png', import.meta.url)).toString('base64')}`;

let fontCss: string | null = null;
export function fonts() {
  fontCss ??= [
    ['Noto Sans', '@fontsource/noto-sans', 'noto-sans-latin-400-normal.woff2', 400],
    ['Noto Sans', '@fontsource/noto-sans', 'noto-sans-latin-700-normal.woff2', 700],
    ['Noto Sans Arabic', '@fontsource/noto-sans-arabic', 'noto-sans-arabic-arabic-400-normal.woff2', 400],
    ['Noto Sans Arabic', '@fontsource/noto-sans-arabic', 'noto-sans-arabic-arabic-700-normal.woff2', 700],
  ].map(([family, pkg, file, weight]) => `@font-face{font-family:'${family}';font-weight:${weight};src:url(data:font/woff2;base64,${font(pkg as string, file as string)}) format('woff2');}`).join('\n');
  return fontCss;
}

export const escape = (v: unknown) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
/** Escaped user text, isolated so English inside Arabic (and vice versa) keeps its own direction and punctuation. Text content only. */
export const esc = (v: unknown) => { const s = escape(v); return s ? `<bdi>${s}</bdi>` : ''; };
export const money = (v: string | number | null | undefined) => Number(v ?? 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
export const qty = (v: string | number) => Number(v).toLocaleString('en-US', { maximumFractionDigits: 3 });
export const para = (v: string | null | undefined) => esc(v).replace(/\n/g, '<br>');
const lines = (v: string | null | undefined) => String(v ?? '').split('\n').map((s) => s.trim()).filter(Boolean);
export const fmtDate = (v: string | Date | null | undefined) => {
  if (!v) return '';
  const d = typeof v === 'string' ? new Date(v.length === 10 ? `${v}T00:00:00Z` : v) : v;
  return `<bdi>${d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: '2-digit', timeZone: 'Asia/Riyadh' }).replace(/ /g, '-')}</bdi>`;
};
const days = (from: Date, to: string) => Math.round((new Date(`${to}T00:00:00Z`).getTime() - Date.UTC(from.getUTCFullYear(), from.getUTCMonth(), from.getUTCDate())) / 86400000);
const letter = (i: number) => (i < 26 ? String.fromCharCode(65 + i) : `${String.fromCharCode(65 + Math.floor(i / 26) - 1)}${String.fromCharCode(65 + (i % 26))}`);

export interface QuotationDoc {
  rev: any;
  lines: any[];
  customer: any;
  contact: any;
  company: any;
  tender: any;
  signatory?: any;
}

export function renderQuotationHtml(doc: QuotationDoc, opts: { language: PdfLanguage; draft: boolean }): string {
  const { rev, customer, contact, company, tender, signatory } = doc;
  const lang = opts.language;
  const en = lang !== 'ar';
  const ar = lang !== 'en';
  const rtl = lang === 'ar';
  /** Label in the chosen language(s). */
  const L = (e: string, a: string) => (lang === 'bilingual' ? `${e} <span class="ar">${a}</span>` : en ? e : `<span class="ar">${a}</span>`);
  /** Content field: prefer the language's own text, fall back to the other. */
  const T = (base: string) => {
    const e = rev[`${base}_en`];
    const a = rev[`${base}_ar`];
    if (lang === 'en') return e || a;
    if (lang === 'ar') return a || e;
    return null;
  };
  /** Bilingual block: side by side when both exist, else single. */
  const B = (base: string, render: (v: string) => string) => {
    if (lang !== 'bilingual') { const v = T(base); return v ? render(v) : ''; }
    const e = rev[`${base}_en`];
    const a = rev[`${base}_ar`];
    if (e && a) return `<div class="cols"><div>${render(e)}</div><div class="ar" dir="rtl">${render(a)}</div></div>`;
    return e ? render(e) : a ? `<div class="ar" dir="rtl">${render(a)}</div>` : '';
  };
  const cur = esc(rev.currency);
  const issueDate = rev.submitted_to_client_at ?? rev.approved_at ?? new Date().toISOString();
  const validityDays = rev.valid_until ? days(new Date(issueDate), rev.valid_until) : null;
  const title = esc(rev.subject || rev.quotation_title);
  const customerName = rtl && customer.name_ar ? customer.name_ar : customer.name_en;
  const rfpRef = rev.client_rfp_reference || tender?.client_reference || '';
  const location = rev.project_location || '';
  const companyNames = `<span class="ar">${esc(company.legal_name_ar)}</span><br>${esc(company.legal_name_en)}`;
  const contactLine = [company.website?.replace(/^https?:\/\//, ''), company.email, company.phone].filter(Boolean).map(esc).join(', ');

  const pageHeader = `<div class="phead"><img src="${LOGO}" alt="REQAZ" class="logo-sm"><div class="pco">${companyNames}</div></div>`;

  // 1. Cover -------------------------------------------------------------------
  const coverRows: [string, string, string][] = [
    ['Prepared For', 'مقدم إلى', esc(customerName)],
    ...(location ? [['Location', 'الموقع', esc(location)] as [string, string, string]] : []),
    ...(rfpRef ? [['RFP Reference', 'مرجع الطلب', esc(rfpRef)] as [string, string, string]] : []),
    ['Reference', 'المرجع', esc(rev.reference)],
    ['Revision', 'المراجعة', String(rev.revision_no)],
    ['Date', 'التاريخ', fmtDate(issueDate)],
    ...(validityDays !== null ? [['Validity (days)', 'الصلاحية (أيام)', String(validityDays)] as [string, string, string]] : []),
  ];
  const cover = `<section class="page cover">
    <img src="${LOGO}" alt="REQAZ" class="logo-lg">
    <div class="proposal-for">${L('Proposal for', 'عرض فني ومالي لـ')}</div>
    <div class="cover-title">${title}</div>
    ${rev.project_name ? `<div class="cover-sub">${esc(rev.project_name)}</div>` : ''}
    <table class="cover-meta">${coverRows.map(([e, a, v]) => `<tr><th>${L(e, a)}</th><td>${v}</td></tr>`).join('')}</table>
    <div class="cover-foot"><div>${contactLine}<br>${esc(company.address_en ?? '')}</div><div class="end">${companyNames}</div></div>
  </section>`;

  // 2. Cover letter --------------------------------------------------------------
  const letterBody = B('cover_letter', para);
  const sigName = rtl && signatory?.full_name_ar ? signatory.full_name_ar : signatory?.full_name;
  const coverLetter = letterBody ? `<section class="page">
    <table class="pwrap"><thead><tr><td>${pageHeader}</td></tr></thead><tbody><tr><td>
    <table class="refbox"><tr><th>${L('Quotation Ref', 'مرجع العرض')}</th><td>${esc(rev.reference)}</td></tr>
      <tr><th>${L('Quotation Date', 'تاريخ العرض')}</th><td>${fmtDate(issueDate)}</td></tr>
      ${rfpRef ? `<tr><th>${L('RFP Ref', 'مرجع الطلب')}</th><td>${esc(rfpRef)}</td></tr>` : ''}</table>
    <div class="h-blue">${L('Proposal for', 'عرض لـ')}</div><div class="h-red">${title}</div>
    <p class="strong">${L('To', 'إلى')} : ${esc(customerName)}</p>
    ${contact || rev.cc ? `<p>${contact ? `${L('Attn', 'عناية')} : ${esc(contact.full_name)}${contact.position ? ` – ${esc(contact.position)}` : ''}` : ''}${rev.cc ? `${contact ? '  |  ' : ''}Cc : ${esc(rev.cc)}` : ''}</p>` : ''}
    <div class="letter">${letterBody}</div>
    <div class="sign-block">${L('Yours sincerely', 'وتفضلوا بقبول فائق الاحترام')}<br><br>
      <strong>${esc(sigName)}</strong>${signatory?.job_title ? `<br>${esc(signatory.job_title)}` : ''}<br>${esc(company.legal_name_en)}
      ${signatory?.phone ? `<br>${esc(signatory.phone)}` : ''}${signatory?.email ? `<br>${L('e-mail', 'البريد الإلكتروني')} : ${esc(signatory.email)}` : ''}</div>
  </td></tr></tbody></table></section>` : '';

  // 3. Summary & terms -------------------------------------------------------------
  const listBlock = (base: string, numbered: boolean) => B(base, (v) => {
    const items = lines(v);
    return numbered
      ? `<ol class="list">${items.map((x) => `<li>${esc(x.replace(/^\d+\s*[-.)]\s*/, ''))}</li>`).join('')}</ol>`
      : `<ul class="dash">${items.map((x) => `<li>${esc(x.replace(/^[-•]\s*/, ''))}</li>`).join('')}</ul>`;
  });
  const schedule = (rev.schedule ?? []) as { label: string; description: string; duration: string }[];
  const milestones = (rev.payment_milestones ?? []) as { description: string; percent: number }[];
  const msTotal = milestones.reduce((a, m) => a + Number(m.percent), 0);
  const kv = (e: string, a: string, body: string) => (body ? `<div class="kv"><div class="k">${L(e, a)}</div><div class="v">${body}</div></div>` : '');
  const validityText = rev.valid_until
    ? (rtl ? `العرض صالح لمدة ${validityDays} يوماً حتى ${fmtDate(rev.valid_until)}.` : `Quotation is valid for ${validityDays} days, till ${fmtDate(rev.valid_until)}.`)
    : '';
  const summary = `<section class="page">
    <table class="pwrap"><thead><tr><td>${pageHeader}</td></tr></thead><tbody><tr><td>
    ${B('executive_summary', (v) => `<h2>${L('Project Executive Summary', 'الملخص التنفيذي للمشروع')}</h2><div class="p">${para(v)}</div>`)}
    <div class="lump"><span>${L(`Total Lump Sum (${cur})`, 'المبلغ الإجمالي المقطوع')}</span><strong>${money(rev.net_amount)}</strong><span class="muted">${L('(VAT Exclusive)', '(غير شامل ضريبة القيمة المضافة)')}</span></div>
    ${(T('scope') || rev.scope_en || rev.scope_ar) ? `<h2>${L('Project Scope', 'نطاق المشروع')}</h2>${listBlock('scope', true)}` : ''}
    ${schedule.length ? `<h2>${L('Delivery & Execution', 'التسليم والتنفيذ')}</h2>
      <table class="grid"><thead><tr><th>${L('Stage', 'المرحلة')}</th><th>${L('Description', 'الوصف')}</th><th class="n">${L('Est. Time', 'المدة المقدرة')}</th></tr></thead>
      <tbody>${schedule.map((s) => `<tr><td>${esc(s.label)}</td><td>${esc(s.description)}</td><td class="n">${esc(s.duration)}</td></tr>`).join('')}</tbody></table>` : ''}
    ${(T('general_terms') || rev.general_terms_en || rev.general_terms_ar) ? `<h2>${L('Terms', 'الشروط')}</h2>${listBlock('general_terms', false)}` : ''}
    ${(T('exclusions') || rev.exclusions_en || rev.exclusions_ar) ? `<h2>${L('Exclusions', 'الاستثناءات')}</h2>${listBlock('exclusions', false)}` : ''}
    <div class="kvs">
      ${kv('Validity', 'الصلاحية', validityText)}
      ${kv('Delivery & Execution', 'مدة التنفيذ', B('completion_period', para))}
      ${kv('Warranty', 'الضمان', B('warranty', para))}
      ${kv('Payment terms', 'شروط الدفع', B('payment_terms', para) + (milestones.length ? `
        <table class="grid ms"><tbody>${milestones.map((m) => `<tr><td>${esc(m.description)}</td><td class="n">${Number(m.percent)}%</td><td class="n">${money(Number(rev.net_amount) * Number(m.percent) / 100)}</td></tr>`).join('')}
        <tr class="tot"><td>${L('Total', 'الإجمالي')}</td><td class="n">${msTotal}%</td><td class="n">${money(Number(rev.net_amount) * msTotal / 100)}</td></tr></tbody></table>` : ''))}
    </div>
  </td></tr></tbody></table></section>`;

  // 4. Compliance matrix -------------------------------------------------------------
  const compliance = (rev.compliance ?? []) as { ref: string; requirement: string; status: string }[];
  const complianceHtml = compliance.length ? `<section class="page">
    <table class="pwrap"><thead><tr><td>${pageHeader}</td></tr></thead><tbody><tr><td><h2>${L('Compliance Matrix', 'مصفوفة الامتثال')}</h2>
    <table class="grid"><thead><tr><th>${L('RFQ §', 'البند')}</th><th>${L('Requirement', 'المتطلب')}</th><th>${L('Compliance', 'الامتثال')}</th></tr></thead>
    <tbody>${compliance.map((c) => `<tr><td>${esc(c.ref)}</td><td>${esc(c.requirement)}</td><td class="${/^comply$/i.test(c.status) ? 'ok' : 'warn'}">${esc(c.status)}</td></tr>`).join('')}</tbody></table>
  </td></tr></tbody></table></section>` : '';

  // 5. Financial proposal ---------------------------------------------------------------
  const desc = (l: any) => {
    if (lang === 'en') return para(l.description_en);
    if (lang === 'ar') return l.description_ar ? `<span class="ar">${para(l.description_ar)}</span>` : para(l.description_en);
    return `${para(l.description_en)}${l.description_ar ? `<div class="ar sub-ar">${para(l.description_ar)}</div>` : ''}`;
  };
  type Group = { section: string | null; lines: any[] };
  const groups: Group[] = [];
  for (const l of doc.lines) {
    const s = l.section || null;
    const g = groups.at(-1);
    if (g && g.section === s) g.lines.push(l); else groups.push({ section: s, lines: [l] });
  }
  let rows = '';
  if (rev.price_display === 'lump_sum_sections') {
    groups.forEach((g, gi) => {
      const total = g.lines.reduce((a, l) => a + Number(l.sell_total), 0);
      rows += `<tr class="main"><td class="c">${gi + 1}.0</td><td>${esc(g.section ?? '')}</td><td class="c">LS</td><td class="n">1</td><td class="n">${money(total)}</td><td class="n">${money(total)}</td></tr>`;
      g.lines.forEach((l, li) => {
        rows += `<tr><td class="c">${esc(l.item_code || letter(li))}</td><td>${desc(l)}</td><td class="c">${esc(l.unit)}</td><td class="n">${qty(l.quantity)}</td><td></td><td></td></tr>`;
      });
    });
  } else {
    let n = 0;
    for (const g of groups) {
      if (g.section) rows += `<tr class="sect"><td colspan="6">${esc(g.section)}</td></tr>`;
      for (const l of g.lines) {
        n += 1;
        rows += `<tr><td class="c">${esc(l.item_code || n)}</td><td>${desc(l)}</td><td class="c">${esc(l.unit)}</td><td class="n">${qty(l.quantity)}</td><td class="n">${money(l.sell_rate)}</td><td class="n">${money(l.sell_total)}</td></tr>`;
      }
    }
  }
  const words = (l: 'en' | 'ar') => amountInWords(rev.net_amount, l, rev.currency);
  const financial = `<section class="page">
    <table class="pwrap"><thead><tr><td>${pageHeader}</td></tr></thead><tbody><tr><td>
    <div class="h-blue">${L('Financial Proposal', 'العرض المالي')}</div><div class="h-red">${title}</div>
    <table class="fhead"><tr>
      <td>${rev.project_name ? `<div><b>${L('Project name', 'اسم المشروع')}:</b> ${esc(rev.project_name)}</div>` : ''}
        <div><b>${L('Quotation Ref.', 'مرجع العرض')}</b> ${esc(rev.reference)}</div><div><b>${L('Quotation Date', 'تاريخ العرض')}</b> ${fmtDate(issueDate)}</div></td>
      <td><div><b>${L('Client', 'العميل')} :</b> ${esc(customerName)}</div>${customer.vat_number ? `<div><b>${L('Client VAT No.', 'الرقم الضريبي للعميل')} :</b> ${esc(customer.vat_number)}</div>` : ''}
        ${rfpRef ? `<div><b>${L('RFP Ref', 'مرجع الطلب')} :</b> ${esc(rfpRef)}</div>` : ''}${location ? `<div><b>${L('Location', 'الموقع')} :</b> ${esc(location)}</div>` : ''}
        ${contact ? `<div><b>${L('Attn', 'عناية')} :</b> ${esc(contact.full_name)}</div>` : ''}</td></tr></table>
    <table class="boq"><thead><tr><th class="c" style="width:6%">#</th><th>${L('Description', 'الوصف')}</th><th class="c" style="width:7%">${L('Unit', 'الوحدة')}</th>
      <th class="n" style="width:8%">${L('QTY', 'الكمية')}</th><th class="n" style="width:13%">${L('Unit Price', 'سعر الوحدة')}<br>${cur}</th><th class="n" style="width:15%">${L('Total Amount', 'المبلغ الإجمالي')}<br>${cur}</th></tr></thead>
      <tbody>${rows}</tbody></table>
    <div class="closing">
    <table class="totals">
      <tr><td>${L('TTL', 'المجموع')}</td><td>${cur}</td><td class="n">${money(rev.subtotal)}</td></tr>
      ${Number(rev.discount_amount) > 0 ? `<tr><td>${L('Discount', 'الخصم')}</td><td>${cur}</td><td class="n">(${money(rev.discount_amount)})</td></tr>
        <tr><td>${L('TTL after discount', 'المجموع بعد الخصم')}</td><td>${cur}</td><td class="n">${money(rev.net_amount)}</td></tr>` : ''}
      <tr><td>${L('VAT', 'ضريبة القيمة المضافة')}</td><td>${Number(rev.vat_rate)}%</td><td class="n">${money(rev.vat_amount)}</td></tr>
      <tr class="net"><td>${L('NET', 'الصافي شامل الضريبة')}</td><td>${cur}</td><td class="n">${money(rev.total_amount)}</td></tr>
    </table>
    <div class="words"><b>${L('TTL', 'المجموع')}</b> ${en ? esc(words('en')) : ''}${ar ? `<div class="ar">${esc(words('ar'))}</div>` : ''} <span class="muted">${L('(VAT EXCLUSIVE)', '(غير شامل الضريبة)')}</span></div>
    ${signatory?.email ? `<div class="po">${L(`Order confirmation and purchase order to be sent to ${esc(signatory.email)}`, `يرجى إرسال تأكيد الطلب وأمر الشراء إلى ${esc(signatory.email)}`)}<br>
      ${L('Kindly include this quotation reference within your purchase order', 'يرجى ذكر مرجع هذا العرض في أمر الشراء')}</div>` : ''}
    <div class="sign"><div>${L('Prepared by', 'أعده')}<br><strong>${esc(rev.prepared_by_name)}</strong></div>
      <div>${L('Approved by', 'اعتمده')}<br><strong>${esc(rev.approved_by_name ?? '')}</strong></div>
      <div>${L('Customer acceptance', 'قبول العميل')}<br>&nbsp;</div></div>
    </div>
  </td></tr></tbody></table></section>`;

  return `<!doctype html><html lang="${rtl ? 'ar' : 'en'}" dir="${rtl ? 'rtl' : 'ltr'}"><head><meta charset="utf-8"><style>
${fonts()}
@page{size:A4;margin:14mm 12mm 16mm}
*{box-sizing:border-box}
body{font-family:'Noto Sans','Noto Sans Arabic',sans-serif;font-size:9.5pt;color:#1a1a1a;margin:0;line-height:1.45}
.ar{font-family:'Noto Sans Arabic','Noto Sans',sans-serif;unicode-bidi:isolate}
.page{page-break-after:always;position:relative}
.page:last-of-type{page-break-after:auto}
.muted{color:#595959;font-weight:400}
.cover{min-height:255mm;display:flex;flex-direction:column}
.logo-lg{width:34mm;margin:18mm auto 22mm;display:block}
.proposal-for{font-size:16pt;font-weight:700;color:#C49A72}
.cover-title{font-size:22pt;font-weight:700;color:#1F3A33;margin:4mm 0 3mm;line-height:1.25}
.cover-sub{font-size:12pt;color:#595959;margin-bottom:14mm}
.cover-meta{border-collapse:collapse;margin-top:10mm;font-size:10.5pt}
.cover-meta th{text-align:start;padding:2mm 8mm 2mm 0;white-space:nowrap;vertical-align:top}
.cover-meta td{padding:2mm 0}
.cover-foot{margin-top:auto;display:flex;justify-content:space-between;color:#595959;font-size:8.5pt;border-top:1px solid #C49A72;padding-top:3mm}
.cover-foot .end{text-align:end}
.pwrap{width:100%;border-collapse:collapse}.pwrap>thead>tr>td,.pwrap>tbody>tr>td{padding:0}
.phead{display:flex;justify-content:space-between;align-items:center;border-bottom:2px solid #C49A72;padding-bottom:2mm;margin-bottom:6mm}
.logo-sm{height:15mm}
.pco{text-align:end;color:#404040;font-size:9pt}
h2{font-size:12pt;color:#1F3A33;margin:4.5mm 0 2mm;padding-bottom:1mm;border-bottom:1px solid #e3e3e3}
.h-blue{font-size:13pt;font-weight:700;color:#2F5D8A}
.h-red{font-size:12pt;font-weight:700;color:#C00000;margin-bottom:5mm}
.refbox{margin-inline-start:auto;border-collapse:collapse;margin-bottom:8mm}
.refbox th{text-align:start;padding:1mm 4mm 1mm 0}.refbox td{color:#595959}
.strong{font-weight:700}
.letter{margin:6mm 0 10mm;line-height:1.6}
.letter .cols>div{line-height:1.6}
.sign-block{margin-top:8mm}
.cols{display:flex;gap:8mm}.cols>div{flex:1}
.lump{display:flex;align-items:baseline;gap:4mm;justify-content:center;margin:6mm 0;padding:3mm;border:1px solid #C49A72;background:#fbf6f1;font-size:11pt}
.lump strong{font-size:14pt}
ol.list{margin:0;padding-inline-start:6mm}ol.list li{margin:.6mm 0}
ul.dash{margin:0;padding-inline-start:5mm;list-style:'- '}ul.dash li{margin:.6mm 0}
table.grid{width:100%;border-collapse:collapse;margin:1mm 0 2mm}
.grid th{background:#1F3A33;color:#fff;text-align:start;padding:1.6mm 2mm;font-size:8.5pt}
.grid td{border-bottom:1px solid #e3e3e3;padding:1.4mm 2mm;vertical-align:top}
.grid .tot td{font-weight:700;border-top:1.5px solid #1F3A33}
.grid td.ok{color:#1E7B34;font-weight:700}.grid td.warn{color:#C00000;font-weight:700}
.ms{margin-top:2mm}
.kvs{margin-top:4mm}.kv{display:flex;gap:4mm;margin:1.8mm 0;page-break-inside:avoid}.kv .k{width:34mm;flex:none;font-weight:700}.kv .v{flex:1}
.fhead{width:100%;margin:2mm 0 4mm;font-size:9pt}.fhead td{vertical-align:top;width:50%;line-height:1.6}
table.boq{width:100%;border-collapse:collapse}
.boq th{background:#2F5D8A;color:#fff;padding:1.8mm;font-size:8.5pt;text-align:start}
.boq td{padding:1.4mm 1.8mm;border-bottom:1px solid #e6e6e6;vertical-align:top}
.boq tr{page-break-inside:avoid}
.boq tr.main,.boq tr.sect{break-after:avoid;page-break-after:avoid}
.boq tr.main td{font-weight:700;background:#f2f5f9;border-top:1px solid #c9d3df}
.boq tr.sect td{font-weight:700;background:#f2f5f9}
.sub-ar{color:#444;margin-top:.5mm}
.c{text-align:center}.n{text-align:end;white-space:nowrap;font-variant-numeric:tabular-nums}
.boq th.n{text-align:end}.boq th.c{text-align:center}
.totals{margin-inline-start:auto;margin-top:3mm;border-collapse:collapse;min-width:80mm}
.totals td{padding:1.4mm 2.5mm}.totals td:first-child{font-weight:700}
.totals tr.net td{border-top:2px solid #2F5D8A;font-weight:700;font-size:11pt}
.words{margin-top:5mm;padding:2.5mm 3mm;background:#f6f6f6;border-inline-start:3px solid #C49A72}
.po{margin-top:6mm;font-weight:700}
.closing{page-break-inside:avoid}
.sign{display:flex;gap:10mm;margin-top:10mm;page-break-inside:avoid}.sign>div{flex:1;border-top:1px solid #999;padding-top:2mm}
.watermark{position:fixed;top:42%;left:0;right:0;text-align:center;font-size:84pt;color:rgba(200,0,0,.10);transform:rotate(-30deg);font-weight:700;z-index:-1}
</style></head><body>
${opts.draft ? '<div class="watermark">DRAFT مسودة</div>' : ''}
${cover}${coverLetter}${summary}${complianceHtml}${financial}
</body></html>`;
}
