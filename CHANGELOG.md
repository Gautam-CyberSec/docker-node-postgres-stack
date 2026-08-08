# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Versioned migrations in place of the one-shot `init.sql`
- Structured JSON logging with request IDs
- Multi-architecture images
- Kubernetes manifests reusing the same probes
- Signed images and an SBOM

## [1.1.0] — 2026-08-09

### Changed
- Express upgraded from 4.22.2 to **5.2.1**. Validated on a compatibility branch
  through the full suite, not unit tests alone: the compose stack and smoke suite
  ran against it and every response shape and status code matched the Express 4
  baseline exactly. The application needed no changes — async handlers already
  used explicit `try/catch` with `next(err)`, `req.body` was already read with
  optional chaining, and all routes are literal strings, so none of v5's breaking
  changes applied.
- GitHub Actions updated: `checkout@v7`, `setup-node@v7`, `setup-buildx-action@v4`,
  `build-push-action@v7`, `hadolint-action@v3.4.0`.

### Not changed
- Node stays on **22 LTS**. A proposed bump to 25 was declined: 25 is a current
  release, not LTS, and reaches end of life before 22 does. Revisit when Node 26
  enters LTS, moving the base image, CI matrix and documentation together.


## [1.0.0] — 2026-08-08

Initial release.

### Added
- Three-stage Dockerfile: production dependencies, a build stage that runs the
  tests, and a runtime stage carrying neither the toolchain nor dev dependencies.
- `compose.yaml` with startup gated on the database's own health check, so no
  wait-for-it script is needed.
- Separate `/healthz` and `/readyz` endpoints — liveness never touches Postgres.
- 14 unit tests running without a database, including proof that liveness is
  independent of it.
- `scripts/smoke.sh`: end-to-end checks asserting uid 1000, a read-only root
  filesystem, a writable `/tmp`, an unpublished database, and a persisted row.
- CI: hadolint, unit tests on Node 20 and 22, image build with a non-root
  assertion, a multi-stage vs single-stage size comparison, the compose stack
  with smoke tests, Trivy, and a link check.

### Security
- Runs as numeric uid 1000 with a read-only root filesystem and
  `no-new-privileges`.
- Postgres publishes no ports.
- tini as PID 1 so `SIGTERM` reaches the application and in-flight requests drain.
- `.env` excluded from the build context; no secrets in any layer.
- Trivy fails the build on fixable HIGH/CRITICAL findings.

[Unreleased]: https://github.com/Gautam-CyberSec/docker-node-postgres-stack/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/Gautam-CyberSec/docker-node-postgres-stack/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Gautam-CyberSec/docker-node-postgres-stack/releases/tag/v1.0.0
