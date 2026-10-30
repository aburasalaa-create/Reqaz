// Apply pending supabase/migrations/*.sql to the database in DATABASE_URL, each in its own transaction, and record them
// in public.schema_migrations. A database set up by hand (setup-new-project.sql or the staging update) has no record yet,
// so on first run each migration whose objects already exist is recorded as applied instead of being run again.
// Usage: DATABASE_URL=... node scripts/migrate.mjs [--dry-run]
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(join(dirname(fileURLToPath(import.meta.url)), '../apps/api/package.json'));
const { Client } = require('pg');

const dir = join(dirname(fileURLToPath(import.meta.url)), '../supabase/migrations');
const dryRun = process.argv.includes('--dry-run');

// One object each migration creates, used only to recognise migrations applied before tracking existed.
const MARKERS = {
  '20261027000001': `select to_regclass('public.app_users') is not null`,
  '20261027000002': `select to_regclass('public.opportunities') is not null`,
  '20261027000003': `select to_regclass('public.quotations') is not null`,
  '20261027000004': `select exists (select 1 from pg_policies where schemaname = 'public' and policyname = 'customers_select')`,
  '20261027000005': `select exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'quotation_revisions' and column_name = 'payment_milestones')`,
  '20261029000006': `select to_regclass('public.invoices') is not null`,
  '20261030000007': `select exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'company_settings' and column_name = 'bank_accounts')`,
  '20261030000008': `select to_regclass('public.brand_assets') is not null`,
  '20261030000009': `select to_regclass('public.purchase_requests') is not null`,
  '20261030000010': `select exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'company_settings' and column_name = 'open_access')`,
  '20261030000011': `select exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'quotation_lines' and column_name = 'manual_rate')`,
  '20261030000012': `select to_regclass('public.expenses') is not null`,
};

if (!process.env.DATABASE_URL) { console.error('DATABASE_URL is not set'); process.exit(1); }
const c = new Client({ connectionString: process.env.DATABASE_URL, ssl: /localhost|127\.0\.0\.1/.test(process.env.DATABASE_URL) ? false : { rejectUnauthorized: false } });
await c.connect();
try {
  await c.query(`create table if not exists public.schema_migrations (version text primary key, applied_at timestamptz not null default now(), how text not null)`);
  await c.query('alter table public.schema_migrations enable row level security'); // no policies: invisible to app users
  const done = new Set((await c.query('select version from public.schema_migrations')).rows.map((r) => r.version));
  const files = readdirSync(dir).filter((f) => /^\d{14}_.+\.sql$/.test(f)).sort();
  let applied = 0;
  for (const f of files) {
    const version = f.slice(0, 14);
    if (done.has(version)) continue;
    if (!done.size || [...done].every((v) => v < version)) {
      const marker = MARKERS[version];
      if (marker && Object.values((await c.query(marker)).rows[0])[0] === true) {
        console.log(`recorded ${f} (already present)`);
        if (!dryRun) await c.query(`insert into public.schema_migrations (version, how) values ($1, 'detected')`, [version]);
        continue;
      }
    }
    console.log(`${dryRun ? 'would apply' : 'applying'} ${f}`);
    if (dryRun) continue;
    await c.query('begin');
    try {
      await c.query(readFileSync(join(dir, f), 'utf8'));
      await c.query(`insert into public.schema_migrations (version, how) values ($1, 'applied')`, [version]);
      await c.query('commit');
      applied++;
    } catch (e) {
      await c.query('rollback');
      console.error(`FAILED ${f}: ${e.message}`);
      process.exit(1);
    }
  }
  console.log(applied ? `${applied} migration(s) applied` : 'database is up to date');
} finally {
  await c.end();
}
