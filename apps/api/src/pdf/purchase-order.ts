// Purchase order PDF (bilingual, Reqaz branding). Issued orders print the buyer and supplier details frozen at issue.
import { amountInWords } from '@rms/shared';
import { LOGO, esc, fmtDate, fonts, money, para, qty, type PdfLanguage } from './quotation.js';

export interface PurchaseOrderDoc {
  po: any;
  lines: any[];
  buyer: any;       // Reqaz (company settings)
  supplier: any;
  stampDataUrl?: string | null;
}

const price = (v: string | number) => Number(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 4 });

export function renderPurchaseOrderHtml(doc: PurchaseOrderDoc, opts: { language?: PdfLanguage } = {}): string {
  const { po, lines, buyer, supplier } = doc;
  const lang = opts.language ?? 'bilingual';
  const rtl = lang === 'ar';
  const L = (e: string, a: string) => (lang === 'bilingual' ? `<bdi>${e}</bdi><br><span class="ar">${a}</span>` : lang === 'en' ? e : `<span class="ar">${a}</span>`);
  const L1 = (e: string, a: string) => (lang === 'bilingual' ? `<bdi>${e}</bdi> <span class="ar">${a}</span>` : lang === 'en' ? e : `<span class="ar">${a}</span>`);
  const final = po.status !== 'draft' && po.status !== 'cancelled';
  const cur = esc(po.currency);
  const meta: [string, string, string][] = [
    ['PO number', 'رقم أمر الشراء', po.number ? esc(po.number) : '<span class="warn">DRAFT</span>'],
    ['Date', 'التاريخ', po.issue_date ? fmtDate(po.issue_date) : '—'],
  ];
  if (po.request_number) meta.push(['Purchase request', 'طلب الشراء', esc(po.request_number)]);
  if (po.project_number) meta.push(['Project', 'المشروع', `${esc(po.project_number)} — ${esc(po.project_name)}`]);
  if (po.supplier_quote_ref) meta.push(['Your quotation', 'عرض سعركم', esc(po.supplier_quote_ref)]);
  if (po.delivery_date) meta.push(['Delivery date', 'تاريخ التسليم', fmtDate(po.delivery_date)]);
  if (po.payment_terms) meta.push(['Payment terms', 'شروط الدفع', esc(po.payment_terms)]);

  const rows = lines.map((l, i) => `<tr><td class="c">${i + 1}</td><td>${esc(l.description)}${l.item_code ? `<div class="muted sub">${esc(l.item_code)}</div>` : ''}</td>
    <td class="c">${esc(l.unit)}</td><td class="n">${qty(l.quantity)}</td><td class="n">${price(l.unit_price)}</td>
    <td class="n">${Number(l.discount_amount) ? money(l.discount_amount) : '—'}</td><td class="n">${money(l.net_amount)}</td>
    <td class="n">${Number(l.vat_rate).toFixed(0)}%</td><td class="n">${money(Number(l.net_amount) + Number(l.vat_amount))}</td></tr>`).join('');

  const totals: [string, string, string, string?][] = [['Subtotal', 'المجموع', money(po.subtotal)]];
  if (Number(po.discount_total)) totals.push(['Discount', 'الخصم', `(${money(po.discount_total)})`]);
  totals.push(['VAT', 'ضريبة القيمة المضافة', money(po.vat_total)]);
  totals.push(['Total order value', 'إجمالي قيمة الأمر', money(po.total_amount), 'grand']);

  return `<!doctype html><html lang="${rtl ? 'ar' : 'en'}" dir="${rtl ? 'rtl' : 'ltr'}"><head><meta charset="utf-8"><style>
${fonts()}
@page{size:A4;margin:12mm 11mm 16mm}
*{box-sizing:border-box}
body{font-family:'Jost','Noto Sans','Noto Sans Arabic',sans-serif;font-size:8.8pt;color:#1a1a1a;margin:0;line-height:1.4}
.ar{font-family:'Noto Sans Arabic','Jost',sans-serif;unicode-bidi:isolate}
.muted{color:#6D6968}.warn{color:#C00000;font-weight:700}.mono{font-variant-numeric:tabular-nums}
.head{display:flex;justify-content:space-between;align-items:flex-start;border-bottom:2.5px solid #C1A287;padding-bottom:3mm}
.head .logo{height:24mm}.co{font-size:8.2pt;line-height:1.45}.co .nm{font-size:10.5pt;font-weight:700;color:#58595B}.co.end{text-align:end}
h1{margin:5mm 0 3mm;font-size:16pt;color:#58595B;line-height:1.2}h1 .ar{display:block;font-size:14pt}
.parties{display:flex;gap:4mm;margin-bottom:3mm}.parties>div{flex:1}
.box{border:1px solid #e7e2da;border-radius:1.5mm;padding:2mm 2.5mm;margin-bottom:2.5mm;page-break-inside:avoid}
.bh{font-weight:700;color:#58595B;margin-bottom:1mm;border-bottom:1px solid #eee;padding-bottom:.8mm}
table.kv{border-collapse:collapse;width:100%}.kv th{text-align:start;font-weight:600;color:#404040;padding:.5mm 2mm .5mm 0;width:40%;vertical-align:top}.kv td{padding:.5mm 0}
table.lines{width:100%;border-collapse:collapse;margin-top:1mm}
.lines th{background:#58595B;color:#fff;padding:1.4mm;font-size:7.4pt;text-align:start;vertical-align:bottom;line-height:1.25}
.lines td{padding:1.3mm 1.4mm;border-bottom:1px solid #e6e6e6;vertical-align:top}.lines tr{page-break-inside:avoid}
.c{text-align:center}.n{text-align:end;white-space:nowrap;font-variant-numeric:tabular-nums}.lines th.n{text-align:end}.lines th.c{text-align:center}.sub{margin-top:.5mm;font-size:8pt}
.bottom{display:flex;gap:5mm;margin-top:3mm;align-items:flex-start}.bottom>.left{flex:1}
table.tot{border-collapse:collapse;min-width:80mm}.tot td{padding:1.2mm 2.5mm;border-bottom:1px solid #eee}.tot td.n{font-weight:600}
.tot tr.grand td{background:#58595B;color:#fff;font-weight:700;font-size:9.6pt}
.words{margin-top:2.5mm;padding:2mm 2.5mm;background:#f6f3ef;border-inline-start:3px solid #C1A287}
.foot{margin-top:6mm;display:flex;gap:10mm;page-break-inside:avoid}.foot>div{flex:1;border-top:1px solid #999;padding-top:1.5mm;color:#404040}
.stamp{display:block;width:32mm;margin:2mm auto 0;transform:rotate(-6deg);opacity:.92}
.watermark{position:fixed;top:40%;left:0;right:0;text-align:center;font-size:64pt;color:rgba(200,0,0,.10);transform:rotate(-28deg);font-weight:700;z-index:-1}
</style></head><body>
${!final ? `<div class="watermark">${po.status === 'cancelled' ? 'CANCELLED' : 'DRAFT'}</div>` : ''}
<div class="head">
  <div class="co"><div class="nm">${esc(buyer?.legal_name_en)}</div>${esc(buyer?.address_en)}<br>
    VAT No. <bdi class="mono">${esc(buyer?.vat_number) || '—'}</bdi> · CR <bdi class="mono">${esc(buyer?.cr_number) || '—'}</bdi>
    ${buyer?.phone ? `<br>${esc(buyer.phone)}` : ''}${buyer?.email ? ` · ${esc(buyer.email)}` : ''}</div>
  <img class="logo" src="${LOGO}" alt="REQAZ">
  <div class="co end ar" dir="rtl"><div class="nm">${esc(buyer?.legal_name_ar)}</div>${esc(buyer?.address_ar)}<br>
    الرقم الضريبي <bdi class="mono">${esc(buyer?.vat_number) || '—'}</bdi></div>
</div>
<h1>Purchase Order${lang !== 'en' ? '<span class="ar">أمر شراء</span>' : ''}</h1>
<div class="parties">
  <div class="box"><div class="bh">${L1('Order details', 'بيانات الأمر')}</div><table class="kv">
    ${meta.map(([e, a, v]) => `<tr><th>${L1(e, a)}</th><td>${v}</td></tr>`).join('')}
    <tr><th>${L1('Currency', 'العملة')}</th><td>${cur}</td></tr></table></div>
  <div class="box"><div class="bh">${L1('Supplier', 'المورد')}</div><table class="kv">
    <tr><th>${L1('Name', 'الاسم')}</th><td>${esc(supplier?.name_en)}${supplier?.name_ar ? `<div class="ar">${esc(supplier.name_ar)}</div>` : ''}</td></tr>
    ${supplier?.vat_number ? `<tr><th>${L1('VAT No.', 'الرقم الضريبي')}</th><td><bdi class="mono">${esc(supplier.vat_number)}</bdi></td></tr>` : ''}
    ${supplier?.cr_number ? `<tr><th>${L1('CR No.', 'السجل التجاري')}</th><td><bdi class="mono">${esc(supplier.cr_number)}</bdi></td></tr>` : ''}
    ${supplier?.contact_name ? `<tr><th>${L1('Attention', 'عناية')}</th><td>${esc(supplier.contact_name)}</td></tr>` : ''}
    ${supplier?.phone || supplier?.email ? `<tr><th>${L1('Contact', 'التواصل')}</th><td>${esc([supplier.phone, supplier.email].filter(Boolean).join(' · '))}</td></tr>` : ''}
    ${supplier?.city ? `<tr><th>${L1('City', 'المدينة')}</th><td>${esc(supplier.city)}</td></tr>` : ''}
  </table></div>
</div>
${po.delivery_address ? `<div class="box"><div class="bh">${L1('Deliver to', 'التسليم إلى')}</div>${para(po.delivery_address)}</div>` : ''}
<table class="lines"><thead><tr>
  <th class="c">#</th><th>${L('Description', 'الوصف')}</th><th class="c">${L('Unit', 'الوحدة')}</th><th class="n">${L('Qty', 'الكمية')}</th>
  <th class="n">${L('Unit price', 'سعر الوحدة')}</th><th class="n">${L('Discount', 'الخصم')}</th><th class="n">${L('Amount', 'المبلغ')}</th>
  <th class="n">${L('VAT %', 'الضريبة')}</th><th class="n">${L('Total incl. VAT', 'الإجمالي شامل الضريبة')}</th>
</tr></thead><tbody>${rows}</tbody></table>
<div class="bottom">
  <div class="left">
    ${po.terms ? `<div class="box"><div class="bh">${L1('Terms and conditions', 'الشروط والأحكام')}</div>${para(po.terms)}</div>` : ''}
    ${po.notes ? `<div class="box"><div class="bh">${L1('Notes', 'ملاحظات')}</div>${para(po.notes)}</div>` : ''}
    <div class="box muted">${L1('Please quote the PO number on your delivery note and invoice. Invoices must be ZATCA-compliant tax invoices addressed to Reqaz.', 'يرجى ذكر رقم أمر الشراء في مذكرة التسليم والفاتورة، وأن تكون الفاتورة ضريبية متوافقة مع متطلبات هيئة الزكاة والضريبة والجمارك وصادرة باسم ركاز.')}</div>
  </div>
  <div>
    <table class="tot">${totals.map(([e, a, v, cls]) => `<tr class="${cls ?? ''}"><td>${L1(e, a)}</td><td class="n">${v} ${cur}</td></tr>`).join('')}</table>
    <div class="words">${lang !== 'ar' ? `<div>${esc(amountInWords(po.total_amount, 'en', po.currency))}</div>` : ''}${lang !== 'en' ? `<div class="ar" dir="rtl">${esc(amountInWords(po.total_amount, 'ar', po.currency))}</div>` : ''}</div>
  </div>
</div>
<div class="foot"><div>${L1('Requested by', 'الطالب')}</div><div>${L1('Authorised by (Reqaz)', 'اعتماد ركاز')}${final && doc.stampDataUrl ? `<img class="stamp" src="${doc.stampDataUrl}" alt="">` : ''}</div><div>${L1('Accepted by (supplier)', 'قبول المورد')}</div></div>
</body></html>`;
}
