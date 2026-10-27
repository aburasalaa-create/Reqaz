# Phase 1: scope, acceptance and status

Status as of 27 Oct 2026. A feature is marked **Done** only when an automated test exercises it end to end. The tests are:

- 42 unit tests in `packages/shared`.
- 31 API and database tests in `apps/api/test`.
- 2 browser tests in `apps/web/e2e`.

## Done and tested

| Feature | Acceptance criteria | Where it is tested |
|---|---|---|
| Roles and permissions | 9 roles, 21 permissions. Database row-level security blocks reads and writes outside a user's role, even through direct SQL. The last administrator cannot be removed. | `security.test.ts`; e2e test "site engineers cannot reach sales screens" |
| Customers and contacts | Saudi VAT number format is validated, a customer has one primary contact, and customer codes are gap-free. | `workflow.test.ts` |
| Leads | A website lead converts into an opportunity once only. | `workflow.test.ts` |
| Pipeline | Kanban board with stage rules: a customer is needed from tender onwards, "lost" needs a reason, and only an award can mark a deal "won". Stage history is append-only. | `workflow.test.ts`, e2e |
| Follow-ups and tenders | Tenders are numbered, the submission deadline appears on the dashboard, and the tender status follows the quotation. | `workflow.test.ts`, e2e |
| Quotation pricing | The SQL engine matches the TypeScript engine to the halala on 60 random quotations. Calculated fields cannot be written by clients. | `numbering-and-pricing.test.ts`, `workflow.test.ts`, e2e |
| BOQ and terms templates | Templates can be inserted into a draft revision. | `workflow.test.ts`, e2e |
| Approval workflow | The preparer cannot approve their own revision, a rejection needs a comment, revisions lock while pending and once approved, and a new revision supersedes the old one. | `workflow.test.ts`, e2e |
| Proposal PDF in Reqaz format | Pages: cover, letter, summary and terms, schedule, payment milestones, compliance, and the financial proposal (itemised or lump sum). Available in EN, AR or bilingual; drafts are watermarked. The reference format is `<prefix>R00`. | `workflow.test.ts`, e2e; pages also checked visually |
| Payment milestones | They must total 100% before a revision goes for approval. | `workflow.test.ts`, e2e |
| Sent-to-client archive | The exact PDF sent to the client is stored and cannot be deleted. | `workflow.test.ts`, e2e |
| Award | Creates the contract (with a frozen snapshot of the awarded revision) and the project, and marks the opportunity "won". | `workflow.test.ts`, e2e |
| Attachments | Private storage, a permission check on download, and soft delete only. | `workflow.test.ts` |
| Audit trail | Every insert, update and workflow event is recorded with the user, and the log cannot be edited. | `workflow.test.ts`, `security.test.ts` |
| Gap-free numbering | 25 concurrent inserts produce no gaps and no duplicates. | `numbering-and-pricing.test.ts` |
| Arabic / RTL interface | Every screen is translated and the layout mirrors. English text typed in the Arabic interface keeps its own direction. | Checked visually (screenshots), not by an automated test |

## Built but not yet verified on real infrastructure

| Item | What is missing |
|---|---|
| Sign-in through Supabase Auth (JWKS / HS256) | The code path is written. All testing so far used development sign-in. This needs a Supabase project. |
| Supabase Storage driver | Written. Tests used the local disk driver. This needs a Supabase project. |
| `Dockerfile` (single container) | Static serving of the web build is tested locally. The image itself has not been built, because Docker is not available in this environment. |
| GitHub Actions CI (`.github/workflows/ci.yml`) | Written. It will first run once the code is in Reqaz's GitHub repository. |

## Not in Phase 1 (by design)

- Accounting, invoices, VAT returns and ZATCA. Phase 3 will not be called compliant until it passes ZATCA's technical tests.
- Project delivery: tasks, documents, budgets and variations (Phase 2).
- The WordPress enquiry plugin, e-mail/WhatsApp notifications and the AI assistant (Phase 4).
- Importing real company data. Only fictional test data exists, in `supabase/seed.sql`, for development use.

## Points to confirm with Reqaz

- **Real company VAT number.** It is entered in Admin → Company settings. The seed uses a placeholder.
- **Company stamp.** It is not printed on PDFs. It can be added if wanted, for example only on approved revisions.
- **Notes on the ARABSAT template:**
  - The delivery period says 80 working days, but the schedule adds up to 90.
  - Items 10 A–C repeat items 1 C–E.
  - The amount in words had typos.

  RMS calculates the amount in words, so the last point cannot happen in generated proposals.

## Running costs (estimates, to confirm on each vendor's pricing page)

| Item | Approx. monthly cost (USD) |
|---|---|
| Supabase Pro (production project, daily backups) | ~25 |
| Supabase staging project (smallest compute) | ~10 |
| Container hosting, about 1 GB RAM (production + staging) | ~15–40 |
| Point-in-time recovery add-on (recommended before live invoicing) | ~100 |
| GitHub organisation (free plan is enough for a private repository and CI at this size) | 0 |
| Domain/DNS (existing GoDaddy) | already paid |

The expected total before point-in-time recovery is roughly **USD 50–75 per month**.
