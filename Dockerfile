# syntax=docker/dockerfile:1

# Multi-stage: the toolchain needed to install and test never reaches the image
# that ships. See ARCHITECTURE.md for the measured difference.

# ── deps: production dependencies only ───────────────────────────────────────
FROM node:22-alpine AS deps

WORKDIR /app

# Copied alone so this layer is cached on every build where the manifests have
# not changed — which is most of them. Copying the source first would invalidate
# the install on every edit.
COPY app/package.json app/package-lock.json ./

# npm ci installs exactly the lock file, unlike npm install which may resolve
# something newer. --omit=dev keeps test and lint tooling out of the runtime.
RUN npm ci --omit=dev --ignore-scripts

# ── build: full dependencies, used to run the test suite ─────────────────────
FROM node:22-alpine AS build

WORKDIR /app
COPY app/package.json app/package-lock.json ./
RUN npm ci --ignore-scripts
COPY app/ ./
RUN npm test

# ── runtime ──────────────────────────────────────────────────────────────────
#
# Built from a bare Alpine rather than node:22-alpine, and the node binary is
# copied in. Two reasons:
#
#   1. No npm. Nothing at runtime needs a package manager — the entrypoint is
#      `node` and the health check is `node -e`. The first build of this image
#      failed its Trivy gate with 8 HIGH/CRITICAL findings, every one of them in
#      npm's own bundled dependencies and none in application code.
#   2. Actually smaller. Deleting npm in a later layer does not reclaim the
#      bytes; it only writes whiteout entries, which made the image *larger*.
#      Never adding it is the only way to remove it.
#
# tini reaps zombies and forwards signals. Node as PID 1 gets no default SIGTERM
# handler, so without it `docker stop` waits out the grace period and then
# SIGKILLs — a ten second pause per container on every deploy, with in-flight
# requests dropped rather than drained.
FROM alpine:3.21 AS runtime

# Versions pinned to the minor series so a rebuild is reproducible without
# breaking the moment Alpine ships a patch release.
RUN apk add --no-cache \
    libstdc++=~14 \
    ca-certificates=~20241121 \
    tini=~0.19

# The node binary is dynamically linked against libstdc++ and libgcc, both
# pulled in above.
COPY --from=node:22-alpine /usr/local/bin/node /usr/local/bin/node

# Alpine has no `node` user of its own, so create the same uid the official
# image uses.
RUN addgroup -g 1000 app && adduser -D -u 1000 -G app app

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

COPY --from=deps --chown=1000:1000 /app/node_modules ./node_modules
COPY --chown=1000:1000 app/package.json ./
COPY --chown=1000:1000 app/src ./src

# Never root. Combined with a read-only root filesystem in compose.yaml, a
# compromised process cannot modify its own code.
#
# Numeric rather than `USER node`: Kubernetes `runAsNonRoot` resolves the UID
# before the image's /etc/passwd is available, so a named user fails admission
# on some clusters. 1000:1000 is the node image's own `node` user.
USER 1000:1000

EXPOSE 3000

# Uses the readiness endpoint, so the container is only reported healthy once it
# can actually reach Postgres. compose.yaml gates dependent services on this.
# JSON form avoids wrapping the probe in a shell, which would otherwise sit
# between the runtime and the process as an extra PID.
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/readyz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/index.js"]
