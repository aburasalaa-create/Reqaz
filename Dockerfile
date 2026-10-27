# Single container: API + built web app + Chromium for PDFs. Matches playwright-core 1.63.0.
FROM mcr.microsoft.com/playwright:v1.63.0-noble AS build
WORKDIR /app
COPY package.json package-lock.json tsconfig.base.json ./
COPY packages/shared/package.json packages/shared/
COPY apps/api/package.json apps/api/
COPY apps/web/package.json apps/web/
RUN npm ci
COPY packages packages
COPY apps apps
# Public values only; they are compiled into the browser bundle.
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_ANON_KEY
ENV VITE_AUTH_MODE=supabase VITE_API_URL=
RUN npm run typecheck && npm run build -w @rms/web

FROM mcr.microsoft.com/playwright:v1.63.0-noble
WORKDIR /app
ENV NODE_ENV=production PORT=8080 WEB_DIST=/app/apps/web/dist CHROMIUM_PATH=
COPY --from=build /app /app
RUN npm prune --omit=dev --workspaces --include-workspace-root 2>/dev/null || true
USER pwuser
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s CMD node -e "fetch('http://127.0.0.1:8080/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["npx", "tsx", "apps/api/src/server.ts"]
