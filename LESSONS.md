# Engineering Decisions &amp; Lessons Learned

Mistakes made while building this stack and what each one changed. Every entry
below actually happened during development; none are illustrative.

Each lesson records **Problem**, **Cause**, **Discovery**, **Fix** and the
**Engineering Principle** that now prevents it.

Docker was not available on the development machine, so the container work was
verified entirely through CI. That is why most of these were found there.

---

## 1. The vulnerability scan found 8 CVEs, none of them in this code

**Problem**
The first CI run failed its Trivy gate with 8 HIGH/CRITICAL findings, one of them
CRITICAL — in `tar`, `sigstore`, `brace-expansion`, `picomatch` and `ip-address`.
Not one was in `express`, `pg`, or anything written here.

**Cause**
Those are npm's own bundled dependencies, shipped inside `node:22-alpine`. The
runtime image inherited a package manager it never uses: the entrypoint is `node`
and the health check is `node -e`.

**Discovery**
The `vulnerability scan` job on the first push to `main`. Reading the table showed
every finding attributed to `package.json` paths under npm rather than to
application dependencies.

**Fix**
Remove npm from the runtime image entirely. That also removes the ability to
install anything inside a running container, which is worth having independently.

**Engineering Principle**
*A runtime image should contain what the process needs and nothing else.*
Inherited tooling is inherited attack surface, and a scanner attributes its CVEs
to you regardless of who wrote them.

---

## 2. Deleting npm made the image bigger

**Problem**
The obvious fix — `RUN rm -rf /usr/local/lib/node_modules/npm` — took the image
from **160 MB to 165 MB**, making it larger than the single-stage build it is
supposed to beat.

**Cause**
Docker layers are additive. A later layer cannot reclaim bytes from an earlier
one; `rm` records whiteout entries that hide the files while the original data
still ships. The deletion cost space rather than saving it.

**Discovery**
The `image build · size` CI job, which builds a single-stage version of the same
application purely for comparison. Without that comparison the regression would
have been invisible — the image still worked, and every other check passed.

**Fix**
Build the runtime from bare `alpine:3.21` and copy in only the `node` binary.
Result: **137 MB**, against 162 MB single-stage, with npm never present rather
than hidden.

**Engineering Principle**
*You cannot remove something from an image after adding it — only hide it.* If a
thing must not be in the final image, no layer may ever contain it. And a size
comparison in CI is what turns "should be smaller" into a number that can regress
visibly.

---

## 3. A pinned action version that did not exist

**Problem**
The scan job began failing with
`Unable to resolve action aquasecurity/trivy-action@0.28.0`. The job was not
scanning and finding nothing — it was never running at all.

**Cause**
The version was written from memory rather than checked. `0.28.0` is not a tag in
that repository.

**Discovery**
The CI log. Notably, the *first* run had produced a real Trivy table, so the
failure appeared only later and initially looked like a new vulnerability rather
than a resolution error — reading the log rather than the job title was what
separated them.

**Fix**
Queried the GitHub releases API for valid tags and pinned `v0.36.0`.

**Engineering Principle**
*Verify third-party versions against the registry, not against recollection.* A
security gate that silently does not run is worse than no gate, because it
produces a green check for a job that never executed.

---

## 4. Pinned apk versions broke the build, and pinning them correctly would break it later

**Problem**
`hadolint` warns (DL3018) when `apk add` has no version pin, so versions were
added. The build then failed with `ERROR: unable to select packages`.

**Cause**
Two mistakes stacked. The versions were invented rather than looked up. And the
apparent fix — looking up the real ones — is itself a trap: Alpine prunes
superseded package versions from its index, so an exact pin stops resolving the
first time a patch ships, breaking the build for a reason unrelated to any change
in this repository.

**Discovery**
The CI build log gave the first half. The second half came from fetching Alpine's
actual `APKINDEX` for 3.21 to find the correct versions, which made the
pruning behaviour obvious before the fragile fix had been committed.

**Fix**
Pin the base image (`alpine:3.21`), which already constrains the package set to
that branch, and suppress DL3018 with the reasoning written beside it.

**Engineering Principle**
*Pin at the layer that stays resolvable.* Reproducibility that expires is not
reproducibility — and a linter rule is an argument, not an order. A documented
suppression beats compliance that breaks the build later.

---

## 5. The README quoted output that had never been produced

**Problem**
The draft README showed a sample response of `{"id":1,"name":"widget",...}`. The
real response is `{"id":"1",...}` — `id` is a **string**.

**Cause**
The block was written from expectation rather than observation. Postgres `BIGINT`
can exceed what a JSON number represents safely, so node-postgres returns it as
text rather than silently losing precision past 2^53. The invented output was
wrong in a way that would mislead anyone writing a client against it.

**Discovery**
Not discovered by a failure — it was prevented. Recognising the block as
unverifiable without Docker, it was replaced with a placeholder and left empty
until the CI smoke suite had run, then filled from that log. The discrepancy
became visible on comparison.

**Fix**
`scripts/smoke.sh` now prints its responses specifically so documentation can
quote something a machine produced.

**Engineering Principle**
*Never publish output you have not seen a machine produce.* When it cannot be
captured yet, leave a placeholder — an empty space is honest, an invented one is
not, and plausible-looking output is the hardest kind of error to catch later.

---

## 6. `node --test test/` stopped meaning what it used to

**Problem**
`npm test` failed immediately with `Cannot find module '.../app/test'`.

**Cause**
Node 24 treats a directory argument to `--test` as a path to execute rather than a
directory to search.

**Discovery**
First local run of the test suite, before any commit.

**Fix**
Use bare `node --test` and let Node's own discovery locate the files. It also
skips `node_modules` by default, which the explicit path did not.

**Engineering Principle**
*Prefer a tool's own discovery over hand-built paths.* It is shorter, and it
tracks the tool's behaviour across versions instead of encoding one version's.

---

## 7. A repository-wide grep that would have scanned dependencies

**Problem**
The CI step that rejects `github.com/blob/` image URLs greps `--include='*.md' .`.
Run locally after `npm install`, it matched eight files — all inside
`node_modules`, all belonging to other people's projects.

**Cause**
CI operates on a fresh checkout with no `node_modules`, so the bug could not
appear there. It would surface only once a job ordered differently, or when a
contributor ran the check locally.

**Discovery**
Running the full pre-push verification gate locally, after `npm install` had
populated `node_modules`. The check passed in CI throughout.

**Fix**
`--exclude-dir=node_modules`.

**Engineering Principle**
*A check that passes because of what the environment happens to lack is not
passing.* Scope a search deliberately rather than relying on a clean directory.

---

## What this repository does differently as a result

- Every hardening claim in the README is asserted by a test: the build fails if
  the image user regresses to root, and the smoke suite tries to write to `/app`
  and probes the host for an exposed database.
- CI builds a single-stage image purely for comparison, so a size regression is
  visible as a number rather than invisible.
- `scripts/smoke.sh` prints real responses so documentation can quote them.
- The unit suite runs on Node 20 and 22, so the code cannot drift past the runtime
  it claims to support.
- The Trivy gate ignores unfixed CVEs deliberately — failing on vulnerabilities
  with no available patch trains people to ignore the gate.
