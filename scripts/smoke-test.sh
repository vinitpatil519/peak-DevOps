#!/usr/bin/env bash
# End-to-end smoke test through the full path:
#   client -> NGINX Ingress -> frontend (NGINX) -> Apache -> FastAPI -> Redis/Postgres
# Usage: scripts/smoke-test.sh [base_url]     (default http://cloudforge.local)
set -euo pipefail
BASE="${1:-http://cloudforge.local}"
pass=0; fail=0

check() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  PASS  $desc"; pass=$((pass+1)); else echo "  FAIL  $desc"; fail=$((fail+1)); fi
}

echo "Smoke testing $BASE"
check "frontend serves SPA"          sh -c "curl -fsS '$BASE/' | grep -q '<div id=\"root\">'"
check "frontend health"              curl -fsS "$BASE/nginx-health"
check "API info via Apache"          sh -c "curl -fsS '$BASE/api/v1/info' | grep -q cloudforge-api"
check "Apache tier in path"          sh -c "curl -fsSI '$BASE/api/v1/info' | grep -qi 'x-served-by: apache-proxy'"
check "request id propagated"        sh -c "curl -fsSI '$BASE/api/v1/info' | grep -qi 'x-request-id'"
check "catalog from Postgres"        sh -c "curl -fsS '$BASE/api/v1/products' | grep -q CF-HAMMER"
check "second read (Redis cache)"    curl -fsS "$BASE/api/v1/products"
check "stats endpoint"               sh -c "curl -fsS '$BASE/api/v1/stats' | grep -q revenue_cents"
check "order creation"               sh -c "curl -fsS -X POST -H 'Content-Type: application/json' \
                                        -d '{\"product_id\":2,\"quantity\":1,\"customer_email\":\"smoke@cloudforge.dev\"}' \
                                        '$BASE/api/v1/orders' | grep -q total_cents"
check "invalid order rejected (422)" sh -c "test \"\$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
                                        -d '{\"product_id\":1,\"quantity\":0,\"customer_email\":\"x\"}' '$BASE/api/v1/orders')\" = 422"
check "unknown API route -> 404"     sh -c "test \"\$(curl -s -o /dev/null -w '%{http_code}' '$BASE/api/v1/does-not-exist')\" = 404"

echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
