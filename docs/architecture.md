# RMS architecture

Reqaz Management System: a construction CRM, estimating and (later) accounting system for Reqaz United Contracting. Users work in English or Arabic, with full right-to-left layout in Arabic. The base currency is SAR. The system is sized for 1–10 users.

## Components

| Part | Technology | Responsibility |
|---|---|---|
| `apps/web` | React 19, TypeScript, Vite, Tailwind, TanStack Query, i18next | The browser app. It holds public values only: the Supabase URL and the anon key. |
| `apps/api` | Fastify 5, TypeScript, `pg`, zod, playwright-core | The only path to the database. Handles validation, sign-in checks, file storage and PDF rendering. |
| `packages/shared` | TypeScript, decimal.js | The pricing engine (a mirror of the SQL engine), constants, and amounts in words (EN/AR). |
| `supabase/migrations` | PostgreSQL 15+ | The schema, business rules, row-level security, audit and numbering. |
| Supabase | Managed Postgres, Auth and Storage | Accounts, passwords, MFA, backups and a private document bucket. |

```
Browser ──HTTPS──> app.reqaz.com ──> API container ──TLS──> Supabase Postgres (RLS)
   │                                      │
   └── Supabase Auth (sign-in only)       └── Supabase Storage (private bucket, service key server-side only)
```

## Security model

1. **Sign-in.** Users sign in with Supabase Auth, and the browser sends the access token to the API. The API verifies the token through the project's JWKS, or through an HS256 secret on legacy projects.
2. **Every request runs as that user inside Postgres.** The API opens a transaction and runs `set local role authenticated`. It sets `request.jwt.claims` to the user's id, and then runs the queries. This makes row-level security apply exactly as it would through PostgREST, so a bug in the API cannot read or change rows that the user's role does not allow.
3. **Permissions.** Permissions are defined as data: `permissions`, `roles`, `role_permissions` and `user_roles`. Policies call `has_permission('quotations.approve')` and similar checks. The seeded roles are Administrator, General Manager, Sales, Estimation, Project Management, Finance, Site Engineering, Document Control and Procurement.
4. **Privileged keys stay on the server.** The service-role key and the database password exist only in the API's environment. In production, the API refuses to start with development sign-in or with local file storage.
5. **Append-only records.** `audit_events`, `quotation_approvals` and `opportunity_stage_history` are written only by triggers. No role can update or delete them.
6. **Documents.** Files live in a private bucket. Downloads go through the API, which checks access first. A PDF that has been sent to a client cannot be deleted, and attachment metadata is immutable.

## Business rules in the database

These rules are enforced in Postgres, so neither the UI nor the API can bypass them:

- **Numbering.** Numbers are gap-free and never change once assigned. Each number is taken under a row lock on `document_sequences` within the same transaction. Formats: `CUS-00001`, `SUP-00001`, `OPP-2026-0001`, `TND-2026-0001`, `QTN-2026-0001`, `CON-2026-001`, `PRJ-2026-001`.
- **Pricing.** `recalculate_revision` is the authoritative calculation:
  1. Direct cost.
  2. Overhead %.
  3. Contingency %.
  4. Mark-up on cost, or a target margin, which gives a price factor rounded to 10 decimal places.
  5. Each line's sell rate is rounded to the halala.
  6. Discount.
  7. VAT, taken from `vat_codes`.

  Clients cannot write the calculated columns. The TypeScript engine produces the live preview on screen, and a test checks it against the database engine on 60 random quotations.
- **Revision workflow.**
  - The main path is draft → pending approval → approved → submitted → awarded.
  - A rejection needs a comment. The preparer cannot approve their own revision unless `allow_self_approval` is set.
  - Submitting a later revision supersedes the earlier approved or submitted one. Only one open revision is allowed per quotation.
  - Payment milestones must total 100% before a revision can go for approval.
- **Award.** `award_quotation()` is the only way an opportunity becomes "won". It creates the contract, with a frozen snapshot of the awarded revision, and the project, with the budget set to the total cost.
- **Pipeline.** A customer is required from "tender received" onwards. "Lost" requires a reason.

## Quotation PDF

The API builds the PDF from HTML and renders it in headless Chromium, which is needed for correct Arabic shaping. JavaScript is disabled during rendering, all network requests are blocked, and the fonts (Noto Sans and Noto Sans Arabic) are embedded.

The layout follows Reqaz's own proposal (the ARABSAT R10 template):

1. Cover.
2. Cover letter.
3. Summary and terms: scope, delivery schedule, terms, exclusions, validity, delivery, warranty and payment milestones.
4. Compliance matrix.
5. Financial proposal, in one of two layouts:
   - Itemised.
   - Lump sum per section, with lettered sub-items, then TTL / VAT / NET and the amount in words.

Language can be English, Arabic or bilingual. Drafts carry a "DRAFT" watermark. The PDF shows selling prices only, never costs or margin.

## Data model (Phase 1)

| Area | Tables |
|---|---|
| Foundation | `app_users`, `roles`, `permissions`, `role_permissions`, `user_roles`, `company_settings`, `currencies`, `exchange_rates`, `vat_codes`, `document_sequences`, `audit_events` |
| CRM | `customers`, `contacts`, `suppliers`, `leads`, `opportunities`, `opportunity_stage_history`, `follow_ups`, `tenders`, `attachments` |
| Estimating | `boq_templates`, `boq_template_items`, `quotation_templates`, `quotations`, `quotation_revisions`, `quotation_lines`, `quotation_approvals` |
| Hand-over to delivery | `contracts`, `projects` (minimal in Phase 1; extended in Phase 2) |

Every table has `created_at`/`updated_at` and, where it applies, `created_by`. Money values are `numeric(18,2)`, quantities are `numeric(18,3)`, unit costs are `numeric(18,4)`, and percentages are `numeric(7,3)`. The migrations in `supabase/migrations` are the documented schema, with comments on the rules where they are defined.

## Phases

1. **Phase 1 (this build):** authentication, roles, customers, CRM pipeline, tenders, quotations with approval, PDF proposals, and the award that creates a contract and project.
2. **Phase 2:** projects, documents, tasks, budgets and variations. Pending variations never change the contract value.
3. **Phase 3:** accounting, VAT returns, ZATCA e-invoicing and payments. Nothing will be described as ZATCA-compliant until it passes ZATCA's own technical tests.
4. **Phase 4:** a WordPress enquiry plugin or webhook into `leads`, notifications, an AI assistant (never used for accounting entries) and hardening.
