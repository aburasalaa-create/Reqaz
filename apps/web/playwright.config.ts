import { defineConfig } from '@playwright/test';

// Runs the whole stack locally: API (dev auth, local storage) against the rms_e2e database,
// and the Vite dev server. CI resets the database first (see package.json "test:e2e").
const DB = process.env.E2E_DATABASE_URL ?? 'postgres://postgres@localhost:54322/rms_dev';

// In CI the built web app is served by the API itself (same origin, no on-demand Vite compilation),
// which is also how production runs. Locally the Vite dev server is used for fast iteration.
const CI = !!process.env.CI;
const api = {
  command: 'npx tsx src/server.ts',
  cwd: '../api',
  url: 'http://127.0.0.1:8787/health',
  reuseExistingServer: !CI,
  env: { NODE_ENV: 'development', DATABASE_URL: DB, AUTH_MODE: 'dev', STORAGE_LOCAL_DIR: '../../storage-local', ...(CI ? { WEB_DIST: '../web/dist' } : {}) },
};

export default defineConfig({
  testDir: './e2e',
  timeout: 90_000,
  expect: { timeout: 10_000 },
  workers: 1,
  reporter: [['list']],
  use: { baseURL: CI ? 'http://127.0.0.1:8787' : 'http://127.0.0.1:5173', viewport: { width: 1440, height: 900 }, trace: 'retain-on-failure' },
  webServer: CI ? [api] : [
    api,
    { command: 'npx vite --host 127.0.0.1', url: 'http://127.0.0.1:5173', reuseExistingServer: true, env: { VITE_AUTH_MODE: 'dev' } },
  ],
});
