# RMS — Reqaz Management System

Construction CRM, estimating and (later) accounting for Reqaz United Contracting. English/Arabic with full RTL, SAR base currency.

- [Architecture and data model](docs/architecture.md)
- [Phase 1 scope, acceptance criteria, status and running costs](docs/phase1-status.md)
- [Deployment, GoDaddy DNS, backup/restore and rollback](docs/deployment.md)

## Quick start (local)

```
npm install
scripts/db-reset.sh rms_dev --seed   # needs Postgres 15+ on localhost:54322
npm run dev:api                      # http://localhost:8787
npm run dev:web                      # http://localhost:5173 — choose a seeded test user
npm test && npm run test:e2e
```

Test users (development only) are `admin|gm|sales|estimator|pm|site|finance@reqaz.test`.

Secrets belong in the API's environment only (`apps/api/.env.example`). The web app receives public values only.
