# Invoicing (Phase 3a): status

## Built and tested
- Draft invoices, credit notes, debit notes and proforma invoices for customers (`/invoices`), and progress claims from a contract ("Bill progress" on Contracts & projects).
- Calculation happens only in the database (`public.recalculate_invoice`):
  - line net = round(qty × price, 2) − discount
  - VAT is totalled per rate (ZATCA category totals)
  - total = taxable + VAT
  - retention = round(taxable × retention %, 2)
  - payable = total − retention − advance recovery
- Issuing (`invoices.issue` permission) assigns the next gap-free number (INV / CRN / DBN / PRF-YYYY-NNNNN), freezes the seller and buyer details, stamps the time, builds the ZATCA Phase 1 QR (TLV tags 1–5) and archives the bilingual PDF. All of these commit together or not at all.
- Issued documents cannot be changed or deleted, by the API or directly in the database. Corrections use credit or debit notes. A credit note cannot exceed the invoice total that is not yet credited.
- Payments received (RCT numbers) are limited to the amount outstanding. A payment can be voided once, with a reason.
- Tests:
  - `apps/api/test/invoices.test.ts` (9 tests)
  - `apps/web/e2e/invoicing.spec.ts`

## Not done yet: do not rely on these
- **ZATCA Phase 2** (UBL XML, invoice hash chain, cryptographic stamp, clearance and reporting via Fatoora) is not done. RMS invoices must not be described as e-invoicing compliant until they pass ZATCA's own tests. One option under discussion is to hand issued invoices to Wafeq for clearance.
- **Currency:** tax documents are SAR only. Proformas may use any currency.
- **Retention and advance recovery** are shown as deductions from the amount payable and do not change the VAT base. Reqaz's accountant should confirm this treatment before live use.
- No general ledger postings yet.

## Applying to an existing Supabase project
Run `supabase/migrations/20261029000006_invoicing.sql` once in the SQL Editor.

## Brand identity
- Colours come from the Reqaz brand guideline:
  - gold #C1A287
  - sand #E7E2DA
  - grey #6D6968 (Pantone 424 C)
  - dark grey #58595B (Pantone 425 C)
  - near-black #1C1C1D for the dark screens
- The logos are SVGs in `apps/web/src/assets/brand` and `apps/api/assets/reqaz-logo.svg`.
- The guideline fonts (Circe, Room, Noto IKEA Arabic) are commercial and are not in this repository. The app and PDFs use Jost and Noto Sans Arabic instead, which have open licences and a similar geometric style. The licensed fonts can replace them once Reqaz confirms its licence covers web and server (PDF) embedding.
