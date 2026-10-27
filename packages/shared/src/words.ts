// Amounts in words for documents (English and Arabic). Supports up to 999,999,999,999.99.

const EN_ONES = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve',
  'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];
const EN_TENS = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];
const EN_SCALES = ['', 'Thousand', 'Million', 'Billion'];

function enBelow1000(n: number): string {
  const h = Math.floor(n / 100);
  const r = n % 100;
  const parts: string[] = [];
  if (h) parts.push(`${EN_ONES[h]} Hundred`);
  if (r) parts.push(r < 20 ? EN_ONES[r] : EN_TENS[Math.floor(r / 10)] + (r % 10 ? `-${EN_ONES[r % 10]}` : ''));
  return parts.join(' ');
}

export function integerToEnglish(n: number): string {
  if (!Number.isInteger(n) || n < 0 || n >= 1e12) throw new RangeError('Out of range');
  if (n === 0) return 'Zero';
  const groups: number[] = [];
  for (let x = n; x > 0; x = Math.floor(x / 1000)) groups.push(x % 1000);
  const words: string[] = [];
  for (let i = groups.length - 1; i >= 0; i--) {
    if (!groups[i]) continue;
    // British style "and" before a final group below one hundred: "Two Thousand and Five".
    if (i === 0 && words.length && groups[i] < 100) words.push('and');
    words.push(enBelow1000(groups[i]) + (EN_SCALES[i] ? ` ${EN_SCALES[i]}` : ''));
  }
  return words.join(' ');
}

const AR_ONES = ['', 'واحد', 'اثنان', 'ثلاثة', 'أربعة', 'خمسة', 'ستة', 'سبعة', 'ثمانية', 'تسعة', 'عشرة',
  'أحد عشر', 'اثنا عشر', 'ثلاثة عشر', 'أربعة عشر', 'خمسة عشر', 'ستة عشر', 'سبعة عشر', 'ثمانية عشر', 'تسعة عشر'];
const AR_TENS = ['', '', 'عشرون', 'ثلاثون', 'أربعون', 'خمسون', 'ستون', 'سبعون', 'ثمانون', 'تسعون'];
const AR_HUNDREDS = ['', 'مائة', 'مائتان', 'ثلاثمائة', 'أربعمائة', 'خمسمائة', 'ستمائة', 'سبعمائة', 'ثمانمائة', 'تسعمائة'];
// [singular, dual, plural (3–10), singular used after 11+]
const AR_SCALES: [string, string, string, string][] = [
  ['', '', '', ''],
  ['ألف', 'ألفان', 'آلاف', 'ألف'],
  ['مليون', 'مليونان', 'ملايين', 'مليون'],
  ['مليار', 'ملياران', 'مليارات', 'مليار'],
];

function arBelow1000(n: number): string {
  const h = Math.floor(n / 100);
  const r = n % 100;
  const parts: string[] = [];
  if (h) parts.push(AR_HUNDREDS[h]);
  if (r) parts.push(r < 20 ? AR_ONES[r] : (r % 10 ? `${AR_ONES[r % 10]} و${AR_TENS[Math.floor(r / 10)]}` : AR_TENS[Math.floor(r / 10)]));
  return parts.join(' و');
}

export function integerToArabic(n: number): string {
  if (!Number.isInteger(n) || n < 0 || n >= 1e12) throw new RangeError('Out of range');
  if (n === 0) return 'صفر';
  const groups: number[] = [];
  for (let x = n; x > 0; x = Math.floor(x / 1000)) groups.push(x % 1000);
  const words: string[] = [];
  for (let i = groups.length - 1; i >= 0; i--) {
    const g = groups[i];
    if (!g) continue;
    if (i === 0) { words.push(arBelow1000(g)); continue; }
    const [one, two, plural, many] = AR_SCALES[i];
    if (g === 1) words.push(one);
    else if (g === 2) words.push(two);
    else if (g <= 10) words.push(`${arBelow1000(g)} ${plural}`);
    else words.push(`${arBelow1000(g)} ${many}`);
  }
  return words.join(' و');
}

/** e.g. 958090.5 → "Nine Hundred Fifty-Eight Thousand and Ninety Saudi Riyals and Fifty Halalas Only" */
export function amountInWords(amount: string | number, lang: 'en' | 'ar', currency = 'SAR'): string {
  const fixed = Number(amount).toFixed(2);
  const [intPart, frac] = fixed.split('.');
  const whole = Number(intPart);
  const cents = Number(frac);
  if (lang === 'en') {
    const unit = currency === 'SAR' ? 'Saudi Riyals' : currency;
    const minor = currency === 'SAR' ? 'Halalas' : 'Cents';
    return `${integerToEnglish(whole)} ${unit}${cents ? ` and ${integerToEnglish(cents)} ${minor}` : ''} Only`;
  }
  const unit = currency === 'SAR' ? 'ريال سعودي' : currency;
  const minor = currency === 'SAR' ? 'هللة' : 'سنت';
  return `فقط ${integerToArabic(whole)} ${unit}${cents ? ` و${integerToArabic(cents)} ${minor}` : ''} لا غير`;
}
