# Contributing

Issues and pull requests are welcome.

## Before opening a pull request

```bash
make check     # hadolint, shellcheck, shfmt and the unit tests — no Docker
make up        # if you have Docker
make smoke
```

CI runs all of it, plus the image build, a Trivy scan and a link check.

## Conventions

- **Claims are asserted, not described.** If the README says the container runs
  unprivileged, a test must prove it. Anything stated and untested will be asked
  about in review.
- **The HTTP layer takes its dependencies as parameters.** That is what keeps the
  unit suite runnable without a database. New handlers follow the same shape.
- **Dockerfile changes must keep `hadolint` clean** at the warning threshold.
  Suppressions need a comment explaining why.
- **Nothing new runs as root**, and nothing needs a writable root filesystem.
- **No secrets, real hostnames, or real credentials** in any committed file,
  including examples.

## Adding an endpoint

1. Add the handler in `app/src/server.js`, taking its dependencies as arguments.
2. Add unit tests covering the success path, the validation failures, and the
   repository throwing.
3. If it changes container behaviour, add an assertion to `scripts/smoke.sh`.
4. Update the README table if it changes the public surface.

## Reporting a security issue

Do not open a public issue — see [SECURITY.md](SECURITY.md).
