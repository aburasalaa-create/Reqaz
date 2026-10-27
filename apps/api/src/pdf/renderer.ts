import { chromium, type Browser } from 'playwright-core';

export interface PdfRenderer {
  render(html: string): Promise<Buffer>;
  close(): Promise<void>;
}

/** Server-side HTML → PDF with headless Chromium (needed for correct Arabic shaping and RTL layout). */
export function createPdfRenderer(executablePath?: string): PdfRenderer {
  let browser: Promise<Browser> | null = null;
  const getBrowser = () => {
    browser ??= chromium.launch({ executablePath, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
    return browser;
  };
  return {
    async render(html) {
      const b = await getBrowser();
      const ctx = await b.newContext({ javaScriptEnabled: false });
      try {
        const page = await ctx.newPage();
        // Block all network access: documents must render only from inlined content.
        await page.route('**/*', (route) => route.abort());
        await page.setContent(html, { waitUntil: 'load' });
        await page.evaluate(() => document.fonts.ready).catch(() => undefined);
        const pdf = await page.pdf({
          format: 'A4',
          printBackground: true,
          margin: { top: '14mm', bottom: '18mm', left: '12mm', right: '12mm' },
          displayHeaderFooter: true,
          headerTemplate: '<span></span>',
          footerTemplate: `<div style="width:100%;font-size:8px;color:#666;text-align:center;font-family:sans-serif">
            <span class="pageNumber"></span> / <span class="totalPages"></span></div>`,
        });
        return Buffer.from(pdf);
      } finally {
        await ctx.close();
      }
    },
    async close() {
      if (browser) await (await browser).close();
      browser = null;
    },
  };
}
