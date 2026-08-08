# Architecture

Why the stack is shaped this way, and what was rejected.

## Scope

A single Node service and its Postgres, running under Compose on one host. Small
enough to reason about; production-shaped enough that the decisions transfer to
an orchestrator.

Explicitly not a Kubernetes deployment, not a microservice mesh, and not a
scaffolding tool. It is a reference for the container layer itself.

## The three-stage build

| Stage | Contains | Ships? |
|---|---|---|
| `deps` | production `node_modules` from `npm ci --omit=dev` | contents only |
| `build` | full dependencies, source, runs `npm test` | no |
| `runtime` | tini, production modules, `src/`, non-root user | yes |

Manifests are copied before source so the install layer stays cached across
source edits — copying the source first invalidates the install on every change,
which is the single most common reason Docker builds feel slow.

`npm ci` rather than `npm install`: it installs exactly the lock file instead of
resolving something newer at build time. Two builds of the same commit produce
the same dependency tree.

The test suite runs *inside* the build stage, so an image whose tests fail never
gets produced. CI also runs the tests directly, which is faster feedback; the
in-image run is what makes the artefact trustworthy on its own.

## Startup ordering

`depends_on` alone waits for the container to *start*, not for Postgres to be
*usable*. The gap between those two is where `wait-for-it.sh` and retry loops
come from.

```yaml
depends_on:
  db:
    condition: service_healthy
```

Compose holds the app until the database's own health check passes, which
removes the need for a wait script entirely.

The health check itself matters:

```yaml
test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
```

A bare `pg_isready` checks the default database as the default user. The
postgres image creates the application database *after* it first accepts
connections, so a bare check can report healthy while the app's database does
not yet exist. The `-U` and `-d` flags close that window.

## Liveness is not readiness

Two endpoints that answer different questions:

| Endpoint | Question | Touches Postgres | On failure |
|---|---|---|---|
| `/healthz` | Is the process alive? | **No** | Orchestrator restarts the container |
| `/readyz` | Should it receive traffic? | Yes | Traffic is withheld; container keeps running |

Collapsing them into one endpoint that checks the database is the common mistake,
and it inverts the failure mode: a thirty-second database blip causes every app
container to fail liveness and be killed, so the database comes back to a
thundering herd of cold starts. Keeping liveness independent means a database
outage degrades traffic and nothing else.

The unit suite asserts that `/healthz` never calls the repository, so this cannot
regress silently.

## Running unprivileged

Three layers, none of which is sufficient alone:

- **`USER 1000:1000`** — numeric, not `USER node`. Kubernetes `runAsNonRoot`
  resolves the UID before the image's `/etc/passwd` is available, so a named user
  fails admission on some clusters.
- **`read_only: true`** with a `tmpfs` for `/tmp` — the application never writes
  to disk, so nothing needs a writable root. A process that cannot modify its own
  code is a much smaller foothold.
- **`no-new-privileges: true`** — blocks privilege escalation through setuid
  binaries even if one is present.

The smoke suite tries to write to `/app` and fails the build if it succeeds.
A hardening claim that is never exercised is decoration.

## tini as PID 1

PID 1 does not get the default signal handlers every other process gets. Node
installs no `SIGTERM` handler of its own, so a container running `node` directly
ignores `docker stop` until the grace period expires and the runtime sends
`SIGKILL` — ten seconds of delay per container on every deploy, and in-flight
requests dropped rather than drained.

tini occupies PID 1, forwards signals to the application, and reaps zombies. The
application's own handler then closes the HTTP server, drains the pool, and exits.

## Postgres publishes nothing

The database has no `ports:` mapping. It is reachable from the app over the
compose network and from nowhere else.

Publishing `5432:5432` "just for development" puts the database on every
interface of the host, which on a cloud VM with a permissive security group means
the internet. Connecting from the host is still possible when genuinely needed,
via `docker compose exec db psql`.

The smoke suite asserts nothing answers on the host's 5432.

## Configuration

Every value is read from the environment at runtime. Nothing is baked in at build
time, so one image is promoted unchanged from development to production — the
property that makes an artefact traceable.

`createPool` throws on a missing variable, so a misconfigured container fails at
boot rather than serving errors later. Compose uses `${VAR:?message}` so the
stack refuses to start with a named error rather than a confusing runtime one.

## What is deliberately absent

- **A migration tool.** `db/init.sql` runs once, on an empty data directory. Real
  deployments need versioned migrations; adding one here would make the repository
  about the migration tool instead of the container layer. On the roadmap.
- **Nginx or a reverse proxy.** Orthogonal, and covered separately.
- **Kubernetes manifests.** The probes and the non-root UID are already
  k8s-shaped; the manifests are a different repository.
- **Secret management.** `.env` is right at this scale. Anything larger wants a
  secrets manager, which is a platform decision rather than a container one.
