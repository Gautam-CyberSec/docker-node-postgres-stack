#!/usr/bin/env bash
# End-to-end checks against a running stack.
#
#   docker compose up -d --build && ./scripts/smoke.sh
#
# Asserts behaviour the unit tests cannot: that the container actually starts,
# reaches Postgres, runs unprivileged, and cannot write to its own filesystem.
set -uo pipefail

BASE="${BASE_URL:-http://127.0.0.1:${APP_PORT:-3000}}"
SERVICE="${APP_SERVICE:-app}"

PASS=0
FAIL=0

check() {
    local desc="$1" status="$2" detail="${3:-}"
    if [[ "$status" -eq 0 ]]; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n' "$desc"
        [[ -n "$detail" ]] && printf '       %s\n' "$detail"
    fi
    return 0
}

# The stack is gated on Postgres being healthy, but the app still needs a moment
# to open its first connection.
printf '\n== waiting for readiness ==\n'
ready=1
for i in $(seq 1 30); do
    if curl -fsS "$BASE/readyz" >/dev/null 2>&1; then
        printf '  ready after %ss\n' "$i"
        ready=0
        break
    fi
    sleep 1
done
check "the stack became ready" "$ready"
if [[ "$ready" -ne 0 ]]; then
    printf '\n  never became ready — recent logs:\n'
    docker compose logs --tail 40 2>&1 | sed 's/^/    /'
    exit 1
fi

printf '\n== endpoints ==\n'

body="$(curl -fsS "$BASE/healthz")"
grep -q '"status":"ok"' <<<"$body"
check "GET /healthz reports ok" $? "$body"

body="$(curl -fsS "$BASE/readyz")"
grep -q '"status":"ready"' <<<"$body"
check "GET /readyz reports ready" $? "$body"

created="$(curl -fsS -X POST "$BASE/api/items" \
    -H 'content-type: application/json' \
    -d '{"name":"smoke-test-item"}')"
grep -q '"name":"smoke-test-item"' <<<"$created"
check "POST /api/items persists a row" $? "$created"

listed="$(curl -fsS "$BASE/api/items")"
grep -q 'smoke-test-item' <<<"$listed"
check "GET /api/items returns it — the row survived the round trip" $? "$listed"

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/items" \
    -H 'content-type: application/json' -d '{}')"
if [[ "$code" == "400" ]]; then s=0; else s=1; fi
check "POST with no name is rejected (got $code)" "$s"

code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/nope")"
if [[ "$code" == "404" ]]; then s=0; else s=1; fi
check "unknown route returns 404 (got $code)" "$s"

printf '\n== container hardening ==\n'

uid="$(docker compose exec -T "$SERVICE" id -u 2>/dev/null | tr -d '\r')"
if [[ "$uid" == "1000" ]]; then s=0; else s=1; fi
check "process runs as uid 1000, not root (got ${uid:-unknown})" "$s"

# A read-only root filesystem is a claim worth testing rather than trusting.
if docker compose exec -T "$SERVICE" sh -c 'touch /app/breakin 2>/dev/null'; then
    check "root filesystem is read-only" 1 "/app was writable — read_only is not in effect"
else
    check "root filesystem is read-only" 0
fi

# /tmp is the one writable path, mounted as tmpfs.
docker compose exec -T "$SERVICE" sh -c 'touch /tmp/probe && rm /tmp/probe' >/dev/null 2>&1
check "/tmp remains writable for scratch space" $?

# Postgres must not be reachable from the host.
if curl -fsS --max-time 3 "http://127.0.0.1:5432" >/dev/null 2>&1; then
    check "Postgres is not published to the host" 1 "something answered on 5432"
else
    check "Postgres is not published to the host" 0
fi

# Printed so the CI log carries real responses. Documentation that quotes output
# should quote output that was actually produced, not output that looks right.
printf '\n== sample responses ==\n'
printf '  GET  /healthz    %s\n' "$(curl -fsS "$BASE/healthz")"
printf '  GET  /readyz     %s\n' "$(curl -fsS "$BASE/readyz")"
printf '  POST /api/items  %s\n' "$created"
printf '  GET  /api/items  %s\n' "$(curl -fsS "$BASE/api/items")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
