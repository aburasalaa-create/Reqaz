import { loadConfig } from './config.js';
import { createPool } from './db.js';
import { createStorage } from './storage.js';
import { createPdfRenderer } from './pdf/renderer.js';
import { buildApp } from './app.js';

const cfg = loadConfig();
const db = createPool(cfg.DATABASE_URL, cfg.DATABASE_POOL_MAX);
const pdf = createPdfRenderer(cfg.CHROMIUM_PATH);
const app = await buildApp({ cfg, db, storage: createStorage(cfg), pdf });

const shutdown = async () => {
  await app.close();
  await pdf.close();
  await db.end();
  process.exit(0);
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

await app.listen({ port: cfg.PORT, host: cfg.HOST });
