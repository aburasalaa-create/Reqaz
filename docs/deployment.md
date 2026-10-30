# Deploying RMS

Reqaz must own every account below. Use a company e-mail address (for example it@reqaz.com), not a personal one, and switch on two-factor authentication on each account.

## 1. Accounts to create

| Service | Purpose | Notes |
|---|---|---|
| GitHub organisation (e.g. `reqaz`) | Source code, CI | Private repository `rms`. |
| Supabase organisation | Postgres, Auth and Storage | Two projects: `rms-staging` and `rms-production`. |
| Container host | Runs the `Dockerfile` (API, web app and Chromium for PDFs) | Any host that runs a Docker image with about 1 GB RAM, for example Render, Railway, Fly.io or DigitalOcean App Platform. |
| GoDaddy (existing) | DNS for reqaz.com | Only one DNS record is added. The WordPress site is not touched. |

**Region and data protection.** Choose the Supabase and container regions closest to Saudi Arabia that the vendors offer. Before real customer data is loaded, have someone check the hosting location against the Saudi PDPL rules on cross-border transfer.

## 2. Supabase set-up (do this for staging first, then production)

1. Create the project and keep the database password in a password manager.
2. Apply the migrations in order. Either use `supabase db push` from a machine linked to the project, or run each file in `supabase/migrations` in the SQL editor in filename order.
   - Do **not** run `supabase/seed.sql` on production. It contains test users and sample data.
   - Do **not** run `supabase/tests/supabase-shim.sql` anywhere on Supabase. It exists only for local and CI databases.
3. In Storage, create a **private** bucket named `rms-documents`.
4. In Authentication:
   - Turn off public sign-ups.
   - Set the site URL to `https://app.reqaz.com` (staging: the staging URL).
   - Turn on MFA for administrators.
5. Invite the first user from Authentication → Users. The first user to sign in becomes Administrator automatically (`bootstrap_first_admin`). They then assign roles to everyone else from Admin → Users.
6. In Admin → Company settings, enter the real VAT number and CR details, and check the address and signatory names.

## 3. Container configuration

The browser needs two public values: the Supabase URL and the publishable (anon) key. The API hands them to the browser at `/api/public-config` when the page loads, using `SUPABASE_URL` and `SUPABASE_ANON_KEY` (or `VITE_SUPABASE_ANON_KEY`). The API refuses to start if a secret or service-role key is put in that slot. They can also be compiled into the web build as `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` build arguments, which then take priority.

Runtime secrets are set in the host's secret manager, never in the repository. See `apps/api/.env.example`.

```
NODE_ENV=production
DATABASE_URL=<Supabase pooler connection string, transaction mode>
APP_ORIGIN=https://app.reqaz.com
AUTH_MODE=supabase
SUPABASE_URL=https://<project>.supabase.co
SUPABASE_ANON_KEY=<publishable (anon) key — public, sent to the browser>
SUPABASE_SERVICE_ROLE_KEY=<service role key — server only>
STORAGE_DRIVER=supabase
STORAGE_BUCKET=rms-documents
FILE_STORAGE=off
```

`FILE_STORAGE=off` is the production default. The app then works without a storage bucket: issued quotations, invoices and purchase orders are not archived as files, and anyone can download them on demand as PDF or Word from their frozen data. Uploads (attachments, receipts) are hidden. Set `FILE_STORAGE=on` once the `rms-documents` bucket exists.

The container listens on port 8080 and serves the web app, the API under `/api`, and a health check at `/health`.

## 4. GoDaddy DNS for app.reqaz.com

In GoDaddy → My Products → reqaz.com → DNS, add **one** record:

| Type | Name | Value | TTL |
|---|---|---|---|
| CNAME | `app` | the hostname the container host gives you (e.g. `rms-xyz.onrender.com`) | 1 hour |

Leave the existing `@` and `www` records alone. They point to the WordPress site. Once the record resolves, add `app.reqaz.com` as a custom domain on the container host, which then issues the TLS certificate. For staging, use a second CNAME such as `app-staging`.

## 5. Releasing a new version

1. Merge to `main` only after CI has passed: typecheck, unit tests, API tests against a fresh Postgres, and the Playwright browser test.
2. Deploy to staging:
   - Apply any new migration to staging.
   - Deploy the new image.
   - Run through the change by hand.
3. Before touching production, take a backup (section 6).
4. Apply the migration to production, then deploy the same image tag that was tested on staging.
5. Check `/health`, sign in, and open one quotation PDF.

**Migrations are forward-only.** Write each one so that the previous app version still works against the new schema. For example, add columns first and remove old ones in a later release.

## 6. Backup and restore

- **Database.** Supabase Pro takes daily backups. Point-in-time recovery is an optional add-on and is recommended once live invoicing starts. In addition, run a weekly `pg_dump` from a machine Reqaz controls:

  ```
  pg_dump "$DATABASE_URL" --format=custom --no-owner --file=rms-$(date +%F).dump
  ```

  Keep 12 weeks of dumps, encrypted, outside Supabase.
- **Documents.** The `rms-documents` bucket is not included in database backups. Copy it weekly with the Supabase CLI or an S3-compatible sync tool to the same off-site location.
- **Restore test.** Every quarter, restore the latest dump into the staging project and open a few quotations and PDFs. A backup that has never been restored is not proven.

## 7. Rollback

- **App only:** redeploy the previous image tag from the container host's history. This takes about a minute.
- **App plus a migration:** because migrations are additive, roll back the app first. If data must be undone, restore the pre-release backup to a new project, compare the two, and fix forward. Never edit posted or audited records in place.

## 8. Local development

```
# Postgres 15+ on port 54322, then:
scripts/db-reset.sh rms_dev --seed       # schema + test data
npm install
npm run dev:api                          # AUTH_MODE=dev, see apps/api/.env.example
npm run dev:web                          # VITE_AUTH_MODE=dev → pick a seeded user on the login page
npm test                                 # unit + API tests (resets rms_test)
npm run test:e2e                         # browser test, CRM → quotation → award
```

## Automatic staging releases

Every push to `main` runs the tests; when they pass, the `deploy` job in `.github/workflows/ci.yml`:

1. runs `scripts/migrate.mjs`, which applies new files from `supabase/migrations` in their own transactions and records them in `public.schema_migrations` (a database set up by hand is recognised on the first run), then
2. calls the Render deploy hook.

One-time setup: in Render set the service branch to `main`, turn Auto-Deploy off and copy the Deploy Hook URL. In GitHub → Settings → Secrets and variables → Actions add `RENDER_DEPLOY_HOOK_URL` (the hook) and `STAGING_DATABASE_URL` (the same value as `DATABASE_URL` in Render).
