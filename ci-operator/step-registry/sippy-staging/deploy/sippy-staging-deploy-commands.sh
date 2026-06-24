#!/bin/bash
set -euo pipefail

cd /workspace

echo "==> Building frontend (must exist before Go binary embeds it)..."
make npm
make frontend

echo "==> Setting up sippy environment (postgres, redis, build, seed)..."
source hack/agentic_setup.sh

echo "==> Starting sippy server..."
./sippy serve \
  --listen ":8080" \
  --listen-metrics ":2112" \
  --database-dsn="${SIPPY_DATABASE_DSN}" \
  --data-provider postgres \
  --views config/seed-views.yaml \
  --redis-url="${REDIS_URL}" \
  --enable-write-endpoints &
SIPPY_PID=$!

echo "==> Waiting for sippy to be ready..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:8080/api/releases > /dev/null 2>&1; then
    echo "    Sippy is ready."
    break
  fi
  if ! kill -0 "${SIPPY_PID}" 2>/dev/null; then
    echo "ERROR: Sippy process exited unexpectedly."
    exit 1
  fi
  sleep 5
done

if ! curl -sf http://localhost:8080/api/releases > /dev/null 2>&1; then
  echo "ERROR: Sippy did not become ready in time."
  exit 1
fi

echo "==> Starting cloudflared tunnel..."
cloudflared tunnel --url http://localhost:8080 > /tmp/cloudflared.log 2>&1 &
TUNNEL_PID=$!

sleep 10

TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log | head -1 || true)

echo ""
echo "============================================================"
echo "  Sippy Staging Environment"
echo "============================================================"
echo ""
if [[ -n "${TUNNEL_URL}" ]]; then
  echo "  URL: ${TUNNEL_URL}"
else
  echo "  WARNING: Could not detect tunnel URL."
  echo "  Check cloudflared logs below:"
  cat /tmp/cloudflared.log
fi
echo ""
echo "  The environment will remain available for"
echo "  ${STAGING_TIMEOUT} seconds ($(( STAGING_TIMEOUT / 60 )) minutes)."
echo ""
echo "============================================================"
echo ""

echo "==> Staging environment is live. Sleeping for ${STAGING_TIMEOUT} seconds..."
sleep "${STAGING_TIMEOUT}"

echo "==> Staging timeout reached. Shutting down."
kill "${TUNNEL_PID}" 2>/dev/null || true
kill "${SIPPY_PID}" 2>/dev/null || true
