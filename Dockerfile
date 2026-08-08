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
FROM node:22-alpine AS runtime

# tini reaps zombies and forwards signals. Node as PID 1 does not receive a
# default SIGTERM handler, so without this `docker stop` waits out the full
# grace period and then SIGKILLs — a ten second pause on every deploy and
# dropped in-flight requests.
RUN apk add --no-cache tini=~0.19

# npm is not needed to run the application — the entrypoint is `node`, and the
# health check is `node -e`. Removing it deletes a package manager from the
# runtime (so a compromised process cannot install anything) and drops every CVE
# that npm's own bundled dependencies carry. On the first build of this image
# that was 8 findings, 1 of them CRITICAL, none in application code.
RUN rm -rf /usr/local/lib/node_modules/npm \
    /usr/local/bin/npm \
    /usr/local/bin/npx

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

# The node image already provides an unprivileged `node` user. Ownership is set
# during the copy so no recursive chown layer is needed.
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node app/package.json ./
COPY --chown=node:node app/src ./src

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
