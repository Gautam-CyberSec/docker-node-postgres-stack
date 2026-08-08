# Security policy

## Reporting a vulnerability

Email [gautamdem@gmail.com](mailto:gautamdem@gmail.com). Please do not open a
public issue. Acknowledgement within 72 hours.

## Controls, and where they are enforced

| Control | Where | Asserted by |
|---|---|---|
| Runs as uid 1000, never root | `Dockerfile` | CI image inspection + smoke test |
| Read-only root filesystem | `compose.yaml` | Smoke test attempts a write to `/app` |
| `no-new-privileges` | `compose.yaml` | — |
| Postgres not published to the host | `compose.yaml` | Smoke test probes host:5432 |
| No secrets in any image layer | `.dockerignore`, runtime env | `.env` excluded from build context |
| Build toolchain absent from runtime | multi-stage `Dockerfile` | CI image size comparison |
| Fixable HIGH/CRITICAL CVEs block the build | CI | Trivy, `--ignore-unfixed` |
| Errors never leak stack traces to clients | `app/src/server.js` | Unit test |
| Request bodies capped at 64 kb | `app/src/server.js` | — |
| Parameterised SQL only | `app/src/db.js` | — |

## Handling secrets

`.env` is gitignored and excluded from the build context, so credentials cannot
reach an image layer even by accident. `.env.example` carries placeholders only.

The password in CI is a throwaway generated for the run against a database that
is never published. It is not a secret and is not reused.

At a larger scale, replace `.env` with a secrets manager and inject at runtime.
The application reads only from the environment, so nothing in it changes.

## Known limitations

- **`db/init.sql` is not a migration system.** It runs once on an empty data
  directory. Schema changes after first start need a real migration tool.
- **Images are unsigned and ship no SBOM.** Both are on the roadmap.
- **Trivy passes unfixed CVEs.** Nothing can be done about a vulnerability with
  no patched version, and failing on them would train people to ignore the gate.
- **The stack is single-host.** No secrets rotation, no network policy, no mTLS
  between services.
