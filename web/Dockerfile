FROM node:26.13.1-bookworm-slim@sha256:5df79989ed685e09f0a98019db4cebfb22fb9df1a53c0161664a011f7ff6b0f1 AS base

ENV NEXT_TELEMETRY_DISABLED=1 \
    NODE_OPTIONS=--no-experimental-webstorage
WORKDIR /app
RUN npm install --global npm@12.0.1 --no-audit --no-fund

FROM base AS dependencies
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund

FROM base AS builder
COPY --from=dependencies /app/node_modules ./node_modules
COPY . .

# Next inlines NEXT_PUBLIC_* at build time, so they have to be here, not only on the running service.
ARG NEXT_PUBLIC_SITE_URL
ARG NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID
ARG NEXT_PUBLIC_JBCENTER_URL
ARG NEXT_PUBLIC_VERSION
ARG RAILWAY_GIT_COMMIT_SHA

ENV NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL \
    NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID=$NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID \
    NEXT_PUBLIC_JBCENTER_URL=$NEXT_PUBLIC_JBCENTER_URL \
    NEXT_PUBLIC_VERSION=${NEXT_PUBLIC_VERSION:-${RAILWAY_GIT_COMMIT_SHA}}

RUN npm run build

FROM base AS runner
ENV NODE_ENV=production \
    HOSTNAME=0.0.0.0 \
    PORT=3000

ARG NEXT_PUBLIC_VERSION
ARG RAILWAY_GIT_COMMIT_SHA
ENV NEXT_PUBLIC_VERSION=${NEXT_PUBLIC_VERSION:-${RAILWAY_GIT_COMMIT_SHA}}

RUN groupadd --system --gid 1001 nodejs \
    && useradd --system --uid 1001 --gid nodejs --home-dir /app nextjs

COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000

CMD ["node", "server.js"]
