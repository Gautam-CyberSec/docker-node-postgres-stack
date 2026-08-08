# Engineering Decisions &amp; Lessons Learned

Mistakes made while building this repository, and what each one changed. Every
entry below actually happened during development — most were caught by CI, which
is the point of having it.

---

## 1. The vulnerability scan found 8 CVEs, none of them mine

**What happened.** The first CI run failed its Trivy gate with 8 HIGH/CRITICAL
findings, one CRITICAL. Every single one was in `tar`, `sigstore`,
`brace-expansion`, `picomatch`, `ip-address` — npm's own bundled dependencies,
shipped inside `node:22-alpine`. Not one was in `express`, `pg`, or any code
here.

**Why.** The runtime image inherited a package manager it never uses. The
entrypoint is `node`; the health check is `node -e`. npm exists in the image
purely because the base image ships it.

**Fix.** Remove npm from the runtime. That also removes the ability to install
anything inside a running container, which is worth having on its own.

**Principle.** *A runtime image should contain what the process needs and
nothing else.* Inherited tooling is inherited attack surface, and a scanner will
attribute its CVEs to you.

---

## 2. Deleting npm made the image bigger

**What happened.** The obvious fix was `RUN rm -rf /usr/local/lib/node_modules/npm`.
The image went from **160 MB to 165 MB** — larger than the single-stage build it
is supposed to beat.

**Why.** Docker layers are additive. A later layer cannot reclaim bytes from an
earlier one; `rm` records whiteout entries that hide the files while the original
data still ships. The delete cost space instead of saving it.

**Fix.** Build the runtime from bare `alpine:3.21` and copy in only the `node`
binary. Result: **137 MB**, versus 162 MB for the single-stage build, with npm
never present rather than hidden.

**Principle.** *You cannot remove something from an image after adding it — only
hide it.* If a thing must not be in the final image, never put it in a layer.

---

## 3. A pinned action version that did not exist

**What happened.** The scan job started failing with
`Unable to resolve action aquasecurity/trivy-action@0.28.0`. The job was not
scanning and finding nothing; it was never running at all.

**Why.** The version was written from memory rather than checked. `0.28.0` is
not a tag in that repository.

**Fix.** Queried the releases API and pinned `v0.36.0`.

**Principle.** *Verify third-party versions against the registry, not against
recollection.* A misremembered version is indistinguishable from a passing job
until you read the log — a security gate that silently does not run is worse
than no gate, because it produces a green check.

---

## 4. Pinned apk versions broke the build, and pinning them correctly would break it later

**What happened.** `hadolint` warns (DL3018) when `apk add` has no version pin,
so versions were added. The build then failed with
`ERROR: unable to select packages`.

**Why.** Two mistakes stacked. The versions were invented rather than looked up.
And the fix for that — looking up the real ones — is itself a trap: Alpine prunes
superseded package versions from its index, so an exact pin stops resolving the
first time a patch ships, breaking the build for a reason unrelated to any change
in the repository.

**Fix.** Pin the base image (`alpine:3.21`), which already constrains the package
set to that branch, and suppress DL3018 with the reasoning written next to it.

**Principle.** *Pin at the layer that stays resolvable.* Reproducibility that
expires is not reproducibility, and a linter rule is an argument rather than an
order — a suppression with a written reason beats compliance that breaks the
build.

---

## 5. The README quoted output that had never been produced

**What happened.** The draft README showed a sample response of
`{"id":1,"name":"widget",...}`. The real response is
`{"id":"1","name":"widget",...}` — `id` is a **string**.

**Why.** The block was written from expectation. Postgres `BIGINT` can exceed
what a JSON number represents safely, so node-postgres returns it as text rather
than silently losing precision past 2^53. Plausible-looking output was wrong in a
way that would mislead anyone writing a client against it.

**Fix.** The block was replaced with a placeholder and left empty until CI had
run, then filled from the smoke suite's log. `scripts/smoke.sh` now prints its
responses specifically so documentation can quote something real.

**Principle.** *Never publish output you have not seen a machine produce.* If it
cannot be captured yet, leave a placeholder — an empty space is honest, an
invented one is not.

---

## 6. `node --test test/` stopped meaning what it used to

**What happened.** `npm test` failed immediately with
`Cannot find module '.../app/test'`.

**Why.** Node 24 treats a directory argument to `--test` as a path to run rather
than a directory to search.

**Fix.** Use bare `node --test` and let Node's own discovery find the files. It
also skips `node_modules` by default, which the explicit path did not.

**Principle.** *Prefer a tool's own discovery over hand-built paths.* It is
shorter, and it tracks the tool's behaviour across versions instead of encoding
one version's.

---

## 7. A repository-wide grep that would have scanned dependencies

**What happened.** The CI step that rejects `github.com/blob/` image URLs greps
`--include='*.md' .`. Run locally after `npm install`, it matched eight files —
all inside `node_modules`, all belonging to other people's projects.

**Why.** CI works on a fresh checkout with no `node_modules`, so the bug was
invisible there. It would only appear once a job ordered differently, or a
contributor ran the check locally.

**Fix.** `--exclude-dir=node_modules`.

**Principle.** *A check that passes because of what the environment happens to
lack is not passing.* Scope the search deliberately rather than relying on a
clean directory.

---

## What this repository does differently as a result

- Every hardening claim in the README is asserted by a test: the build fails if
  the image user regresses to root, and the smoke suite tries to write to `/app`
  and probes the host for an exposed database.
- `scripts/smoke.sh` prints real responses so documentation can quote them.
- CI runs the unit suite on both Node 20 and 22, so the code cannot drift past
  the runtime it claims to support.
- The Trivy gate ignores unfixed CVEs deliberately — failing on vulnerabilities
  with no available patch trains people to ignore the gate.
