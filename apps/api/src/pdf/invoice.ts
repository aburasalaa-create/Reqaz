// Tax invoice, simplified tax invoice, credit/debit note and proforma PDF, bilingual (Arabic is required on KSA tax invoices).
// Issued documents print the seller and buyer details frozen at issue, never the current master data.
import { amountInWords } from '@rms/shared';
import { LOGO, esc, fmtDate, fonts, money, para, qty, type PdfLanguage } from './quotation.js';

export interface InvoiceDoc {
  invoice: any;
  lines: any[];
  seller: any;         // seller_snapshot when issued, else current company settings
  buyer: any;          // buyer_snapshot when issued, else current customer
  original?: any;      // the invoice a credit/debit note refers to
  contract?: any;
  project?: any;
  qrDataUrl?: string | null;
  stampDataUrl?: string | null;  // printed only on issued documents
}

const TITLES: Record<string, [string, string]> = {
  standard: ['Tax Invoice', 'فاتورة ضريبية'],
  simplified: ['Simplified Tax Invoice', 'فاتورة ضريبية مبسطة'],
  credit_note: ['Credit Note', 'إشعار دائن'],
  debit_note: ['Debit Note', 'إشعار مدين'],
  proforma: ['Proforma Invoice', 'فاتورة مبدئية'],
};

export function invoiceTitle(inv: { kind: string; zatca_type: string }): [string, string] {
  return inv.kind === 'invoice' ? TITLES[inv.zatca_type] : TITLES[inv.kind];
}

/** Unit prices keep up to 4 decimals when entered that way. */
const price = (v: string | number) => Number(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 4 });

const address = (p: any, ar = false) => [p?.building_number, p?.street, p?.district, p?.city, p?.postal_code, ar ? null : p?.country]
  .filter(Boolean).join(ar ? '، ' : ', ');

export function renderInvoiceHtml(doc: InvoiceDoc, opts: { language?: PdfLanguage } = {}): string {
  const { invoice: inv, lines, seller, buyer, original, contract, project } = doc;
  const lang = opts.language ?? 'bilingual';
  const rtl = lang === 'ar';
  const L = (e: string, a: string) => (lang === 'bilingual' ? `${e}<br><span class="ar">${a}</span>` : lang === 'en' ? e : `<span class="ar">${a}</span>`);
  const L1 = (e: string, a: string) => (lang === 'bilingual' ? `<bdi>${e}</bdi> <span class="ar">${a}</span>` : lang === 'en' ? e : `<span class="ar">${a}</span>`);
  const [titleEn, titleAr] = invoiceTitle(inv);
  const draft = inv.status !== 'issued';
  const cur = esc(inv.currency);
  const sellerAddr = seller?.address_en || address(seller);
  const sellerAddrAr = seller?.address_ar || '';

  const meta: [string, string, string][] = [
    ['Number', 'الرقم', inv.number ? esc(inv.number) : '<span class="warn">DRAFT</span>'],
    ['Issue date', 'تاريخ الإصدار', inv.issue_date ? fmtDate(inv.issue_date) : '—'],
  ];
  if (inv.supply_date) meta.push(['Supply date', 'تاريخ التوريد', fmtDate(inv.supply_date) + (inv.supply_end_date ? ` – ${fmtDate(inv.supply_end_date)}` : '')]);
  if (inv.due_date && inv.kind !== 'credit_note') meta.push(['Due date', 'تاريخ الاستحقاق', fmtDate(inv.due_date)]);
  if (inv.customer_reference) meta.push(['Your reference', 'مرجعكم', esc(inv.customer_reference)]);
  if (contract) meta.push(['Contract', 'العقد', esc(contract.number)]);
  if (project) meta.push(['Project', 'المشروع', `${esc(project.number)} — ${esc(project.name)}`]);
  if (original) meta.push(['Original invoice', 'الفاتورة الأصلية', `${esc(original.number)} (${fmtDate(original.issue_date)})`]);
  if (inv.note_reason) meta.push(['Reason', 'السبب', esc(inv.note_reason)]);

  const vatRows = new Map<string, { rate: string; taxable: number }>();
  for (const l of lines) {
    const k = `${l.vat_category}-${l.vat_rate}`;
    const row = vatRows.get(k) ?? { rate: l.vat_rate, taxable: 0 };
    row.taxable += Number(l.net_amount);
    vatRows.set(k, row);
  }

  const lineRows = lines.map((l, i) => `<tr>
    <td class="c">${i + 1}</td>
    <td>${esc(l.description_en)}${l.description_ar && lang !== 'en' ? `<div class="ar sub">${esc(l.description_ar)}</div>` : ''}${l.vat_category !== 'S' && l.vat_exemption_reason ? `<div class="sub muted">${esc(l.vat_exemption_reason)}</div>` : ''}</td>
    <td class="c">${esc(l.unit)}</td>
    <td class="n">${qty(l.quantity)}</td>
    <td class="n">${price(l.unit_price)}</td>
    <td class="n">${Number(l.discount_amount) ? money(l.discount_amount) : '—'}</td>
    <td class="n">${money(l.net_amount)}</td>
    <td class="n">${Number(l.vat_rate).toFixed(0)}%</td>
    <td class="n">${money(l.vat_amount)}</td>
    <td class="n">${money(Number(l.net_amount) + Number(l.vat_amount))}</td>
  </tr>`).join('');

  const totals: [string, string, string, string?][] = [
    ['Total (excluding VAT)', 'الإجمالي غير شامل الضريبة', money(inv.subtotal)],
  ];
  if (Number(inv.discount_total)) totals.push(['Discount', 'الخصم', `(${money(inv.discount_total)})`]);
  if (Number(inv.advance_recovery)) totals.push(['Less advance payment recovered (before VAT)', 'يخصم استرداد الدفعة المقدمة (قبل الضريبة)', `(${money(inv.advance_recovery)})`]);
  totals.push(['Total taxable amount', 'الإجمالي الخاضع للضريبة', money(inv.taxable_amount)]);
  totals.push(['Total VAT', 'إجمالي ضريبة القيمة المضافة', money(inv.vat_total)]);
  totals.push(['Total amount due (including VAT)', 'إجمالي المبلغ المستحق شامل الضريبة', money(inv.total_amount), 'grand']);
  if (Number(inv.retention_amount)) totals.push([`Less retention ${Number(inv.retention_pct)}%`, `يخصم ضمان الأعمال ${Number(inv.retention_pct)}%`, `(${money(inv.retention_amount)})`]);
  if (Number(inv.advance_deduction)) totals.push(['Less advance payment recovery', 'يخصم استرداد الدفعة المقدمة', `(${money(inv.advance_deduction)})`]);
  if (Number(inv.retention_amount) || Number(inv.advance_deduction)) totals.push(['Net amount payable', 'صافي المبلغ المستحق الدفع', money(inv.amount_payable), 'grand']);
  const wordsAmount = Number(inv.retention_amount) || Number(inv.advance_deduction) ? inv.amount_payable : inv.total_amount;

  const banks = (Array.isArray(seller?.bank_accounts) ? seller.bank_accounts : []).filter((b: any) => b.show_on_invoices !== false && b.iban);
  const bank = banks.length ? `<div class="box"><div class="bh">${L1('Bank details', 'البيانات البنكية')}</div>
    ${seller?.legal_name_en ? `<div class="muted">${esc(banks[0].account_name || seller.legal_name_en)}</div>` : ''}
    ${banks.map((b: any) => `<div class="bankrow"><strong>${esc(b.bank_name)}</strong><br>IBAN <bdi class="mono">${esc(b.iban)}</bdi>${b.account_number ? ` · A/C <bdi class="mono">${esc(b.account_number)}</bdi>` : ''}</div>`).join('')}</div>` : '';

  const terms = [inv.payment_terms_en || inv.payment_terms_ar ? `<div class="box"><div class="bh">${L1('Payment terms', 'شروط الدفع')}</div>
      ${inv.payment_terms_en && lang !== 'ar' ? `<div>${para(inv.payment_terms_en)}</div>` : ''}${inv.payment_terms_ar && lang !== 'en' ? `<div class="ar" dir="rtl">${para(inv.payment_terms_ar)}</div>` : ''}</div>` : '',
    inv.notes_en || inv.notes_ar ? `<div class="box"><div class="bh">${L1('Notes', 'ملاحظات')}</div>
      ${inv.notes_en && lang !== 'ar' ? `<div>${para(inv.notes_en)}</div>` : ''}${inv.notes_ar && lang !== 'en' ? `<div class="ar" dir="rtl">${para(inv.notes_ar)}</div>` : ''}</div>` : '',
  ].join('');

  const qr = doc.qrDataUrl ? `<img class="qr" src="${doc.qrDataUrl}" alt="ZATCA QR">`
    : inv.kind === 'proforma' ? '' : `<div class="qr qr-ph">${L('QR code on issue', 'رمز الاستجابة عند الإصدار')}</div>`;

  return `<!doctype html><html lang="${rtl ? 'ar' : 'en'}" dir="${rtl ? 'rtl' : 'ltr'}"><head><meta charset="utf-8"><style>
${fonts()}
@page{size:A4;margin:12mm 11mm 16mm}
*{box-sizing:border-box}
body{font-family:'Jost','Noto Sans','Noto Sans Arabic',sans-serif;font-size:8.6pt;color:#1a1a1a;margin:0;line-height:1.4}
.ar{font-family:'Noto Sans Arabic','Jost',sans-serif;unicode-bidi:isolate}
.muted{color:#595959}.warn{color:#C00000;font-weight:700}.mono{font-variant-numeric:tabular-nums;letter-spacing:.2px}
.head{display:flex;justify-content:space-between;align-items:flex-start;border-bottom:2.5px solid #C1A287;padding-bottom:3mm}
.head .logo{height:24mm}
.co{font-size:8.2pt;line-height:1.45}.co .nm{font-size:10.5pt;font-weight:700;color:#58595B}
.co.end{text-align:end}
.title{display:flex;justify-content:space-between;align-items:center;margin:4mm 0 3mm}
.title h1{margin:0;font-size:16pt;color:#58595B;line-height:1.2}
.title h1 .ar{display:block;font-size:14pt}
.qr{width:30mm;height:30mm}.qr-ph{border:1px dashed #aaa;display:flex;align-items:center;justify-content:center;text-align:center;font-size:7pt;color:#888}
.parties{display:flex;gap:4mm;margin-bottom:3mm}.parties>div{flex:1}
.box{border:1px solid #e7e2da;border-radius:1.5mm;padding:2mm 2.5mm;margin-bottom:2.5mm;page-break-inside:avoid}
.bh{font-weight:700;color:#58595B;margin-bottom:1mm;border-bottom:1px solid #eee;padding-bottom:.8mm}
table.kv{border-collapse:collapse;width:100%}.kv th{text-align:start;font-weight:600;color:#404040;padding:.5mm 2mm .5mm 0;width:40%;vertical-align:top}.kv td{padding:.5mm 0}
table.lines{width:100%;border-collapse:collapse;margin-top:1mm}
.lines th{background:#58595B;color:#fff;padding:1.4mm 1.4mm;font-size:7.4pt;text-align:start;vertical-align:bottom;line-height:1.25}
.lines td{padding:1.3mm 1.4mm;border-bottom:1px solid #e6e6e6;vertical-align:top}
.lines tr{page-break-inside:avoid}
.c{text-align:center}.n{text-align:end;white-space:nowrap;font-variant-numeric:tabular-nums}.lines th.n{text-align:end}.lines th.c{text-align:center}
.sub{margin-top:.6mm;font-size:8pt}
.bottom{display:flex;gap:5mm;margin-top:3mm;align-items:flex-start}.bottom>.left{flex:1}
table.tot{border-collapse:collapse;min-width:88mm}
.tot td{padding:1.2mm 2.5mm;border-bottom:1px solid #eee}.tot td.n{font-weight:600}
.tot tr.grand td{background:#58595B;color:#fff;font-weight:700;font-size:9.6pt}
.bankrow{margin-top:1mm}
.words{margin-top:2.5mm;padding:2mm 2.5mm;background:#f6f3ef;border-inline-start:3px solid #C1A287}
.foot{margin-top:6mm;display:flex;gap:10mm;page-break-inside:avoid}.foot>div{flex:1;border-top:1px solid #999;padding-top:1.5mm;color:#404040}
.stamp{display:block;width:32mm;margin:2mm auto 0;transform:rotate(-6deg);opacity:.92}
.watermark{position:fixed;top:40%;left:0;right:0;text-align:center;font-size:64pt;color:rgba(200,0,0,.10);transform:rotate(-28deg);font-weight:700;z-index:-1}
</style></head><body>
${draft ? `<div class="watermark">${inv.status === 'cancelled' ? 'CANCELLED' : 'DRAFT'}</div>` : ''}
<div class="head">
  <div class="co"><div class="nm">${esc(seller?.legal_name_en)}</div>${esc(sellerAddr)}<br>
    VAT No. <bdi class="mono">${esc(seller?.vat_number) || '—'}</bdi> · CR <bdi class="mono">${esc(seller?.cr_number) || '—'}</bdi>
    ${seller?.phone ? `<br>${esc(seller.phone)}` : ''}${seller?.email ? ` · ${esc(seller.email)}` : ''}</div>
  <img class="logo" src="${LOGO}" alt="REQAZ">
  <div class="co end ar" dir="rtl"><div class="nm">${esc(seller?.legal_name_ar)}</div>${esc(sellerAddrAr || address(seller, true))}<br>
    الرقم الضريبي <bdi class="mono">${esc(seller?.vat_number) || '—'}</bdi> · السجل التجاري <bdi class="mono">${esc(seller?.cr_number) || '—'}</bdi></div>
</div>
<div class="title"><h1>${titleEn}${lang !== 'en' ? `<span class="ar">${titleAr}</span>` : ''}</h1>${qr}</div>
<div class="parties">
  <div class="box"><div class="bh">${L1('Invoice details', 'بيانات الفاتورة')}</div><table class="kv">
    ${meta.map(([e, a, v]) => `<tr><th>${L1(e, a)}</th><td>${v}</td></tr>`).join('')}
    <tr><th>${L1('Currency', 'العملة')}</th><td>${cur}</td></tr></table></div>
  <div class="box"><div class="bh">${L1('Customer', 'العميل')}</div><table class="kv">
    <tr><th>${L1('Name', 'الاسم')}</th><td>${esc(buyer?.name_en)}${buyer?.name_ar ? `<div class="ar">${esc(buyer.name_ar)}</div>` : ''}</td></tr>
    ${buyer?.vat_number ? `<tr><th>${L1('VAT No.', 'الرقم الضريبي')}</th><td><bdi class="mono">${esc(buyer.vat_number)}</bdi></td></tr>` : ''}
    ${buyer?.cr_number ? `<tr><th>${L1('CR No.', 'السجل التجاري')}</th><td><bdi class="mono">${esc(buyer.cr_number)}</bdi></td></tr>` : ''}
    ${address(buyer) ? `<tr><th>${L1('Address', 'العنوان')}</th><td>${esc(address(buyer))}</td></tr>` : ''}
  </table></div>
</div>
${inv.title ? `<div class="box"><strong>${esc(inv.title)}</strong></div>` : ''}
<table class="lines"><thead><tr>
  <th class="c">#</th><th>${L('Description', 'الوصف')}</th><th class="c">${L('Unit', 'الوحدة')}</th><th class="n">${L('Qty', 'الكمية')}</th>
  <th class="n">${L('Unit price', 'سعر الوحدة')}</th><th class="n">${L('Discount', 'الخصم')}</th><th class="n">${L('Taxable amount', 'المبلغ الخاضع للضريبة')}</th>
  <th class="n">${L('VAT %', 'نسبة الضريبة')}</th><th class="n">${L('VAT amount', 'مبلغ الضريبة')}</th><th class="n">${L('Total incl. VAT', 'الإجمالي شامل الضريبة')}</th>
</tr></thead><tbody>${lineRows}</tbody></table>
<div class="bottom">
  <div class="left">
    ${vatRows.size > 1 ? `<div class="box"><div class="bh">${L1('VAT breakdown', 'تفصيل الضريبة')}</div><table class="kv">${[...vatRows.values()].map((r) => `<tr><th>${Number(r.rate).toFixed(0)}%</th><td class="n">${money(r.taxable)} ${cur}</td></tr>`).join('')}</table></div>` : ''}
    ${bank}${terms}
  </div>
  <div>
    <table class="tot">${totals.map(([e, a, v, cls]) => `<tr class="${cls ?? ''}"><td>${L1(e, a)}</td><td class="n">${v} ${cur}</td></tr>`).join('')}</table>
    <div class="words">${lang !== 'ar' ? `<div>${esc(amountInWords(wordsAmount, 'en', inv.currency))}</div>` : ''}${lang !== 'en' ? `<div class="ar" dir="rtl">${esc(amountInWords(wordsAmount, 'ar', inv.currency))}</div>` : ''}</div>
  </div>
</div>
<div class="foot"><div>${L1('Prepared by', 'إعداد')}</div><div class="stampcell">${L1('Approved by', 'اعتماد')}${!draft && doc.stampDataUrl ? `<img class="stamp" src="${doc.stampDataUrl}" alt="">` : ''}</div><div>${L1('Received by (customer)', 'استلام العميل')}</div></div>
</body></html>`;
}
