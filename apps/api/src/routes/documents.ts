// Downloading a business document as PDF (rendered by headless Chromium) or as a Word file (the same HTML, no rendering,
// so it is quick and light on small servers). Word opens .doc files written as HTML and can save them as .docx.
import type { FastifyReply } from 'fastify';
import { z } from 'zod';
import type { PdfRenderer } from '../pdf/renderer.js';

export const documentQuery = z.object({
  lang: z.enum(['bilingual', 'en', 'ar']).default('bilingual'),
  format: z.enum(['pdf', 'word']).default('pdf'),
});

const WORD_HEAD = '<html xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:w="urn:schemas-microsoft-com:office:word" xmlns="http://www.w3.org/TR/REC-html40"';

export function toWordHtml(html: string): string {
  return '﻿' + html.replace(/^<!doctype html>\s*<html/i, WORD_HEAD)
    .replace('<head>', '<head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"><!--[if gte mso 9]><xml><w:WordDocument><w:View>Print</w:View></w:WordDocument></xml><![endif]-->');
}

export async function sendDocument(reply: FastifyReply, pdf: PdfRenderer, html: string, pdfName: string, format: 'pdf' | 'word') {
  reply.header('Cache-Control', 'no-store');
  if (format === 'word') {
    const name = pdfName.replace(/\.pdf$/i, '.doc');
    return reply.header('Content-Type', 'application/msword; charset=utf-8')
      .header('Content-Disposition', `attachment; filename="${name}"`).send(toWordHtml(html));
  }
  const file = await pdf.render(html);
  return reply.header('Content-Type', 'application/pdf').header('Content-Disposition', `inline; filename="${pdfName}"`).send(file);
}
