import { describe, expect, it } from 'vitest';
import { amountInWords, integerToArabic, integerToEnglish } from './words';

describe('English amounts in words', () => {
  it.each([
    [0, 'Zero'], [7, 'Seven'], [15, 'Fifteen'], [40, 'Forty'], [99, 'Ninety-Nine'], [100, 'One Hundred'], [101, 'One Hundred One'],
    [1000, 'One Thousand'], [2005, 'Two Thousand and Five'], [12345, 'Twelve Thousand Three Hundred Forty-Five'],
    [958090, 'Nine Hundred Fifty-Eight Thousand and Ninety'], [1000000, 'One Million'],
    [2500000, 'Two Million Five Hundred Thousand'], [1000000001, 'One Billion and One'],
  ])('%i', (n, w) => expect(integerToEnglish(n)).toBe(w));

  it('formats SAR with halalas', () => {
    expect(amountInWords('958090.00', 'en')).toBe('Nine Hundred Fifty-Eight Thousand and Ninety Saudi Riyals Only');
    expect(amountInWords('1101803.50', 'en')).toBe('One Million One Hundred One Thousand Eight Hundred Three Saudi Riyals and Fifty Halalas Only');
  });
});

describe('Arabic amounts in words', () => {
  it.each([
    [1, 'واحد'], [2, 'اثنان'], [11, 'أحد عشر'], [21, 'واحد وعشرون'], [100, 'مائة'], [200, 'مائتان'], [305, 'ثلاثمائة وخمسة'],
    [1000, 'ألف'], [2000, 'ألفان'], [3000, 'ثلاثة آلاف'], [10000, 'عشرة آلاف'], [11000, 'أحد عشر ألف'], [150000, 'مائة وخمسون ألف'],
    [958090, 'تسعمائة وثمانية وخمسون ألف وتسعون'], [1000000, 'مليون'], [2000000, 'مليونان'], [5000000, 'خمسة ملايين'],
    [1250000, 'مليون ومائتان وخمسون ألف'],
  ])('%i', (n, w) => expect(integerToArabic(n)).toBe(w));

  it('formats SAR with halalas', () => {
    expect(amountInWords(958090, 'ar')).toBe('فقط تسعمائة وثمانية وخمسون ألف وتسعون ريال سعودي لا غير');
    expect(amountInWords('15.25', 'ar')).toBe('فقط خمسة عشر ريال سعودي وخمسة وعشرون هللة لا غير');
  });
});
