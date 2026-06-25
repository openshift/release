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

if [[ -n "${TUNNEL_URL}" && "${JOB_TYPE:-}" == "presubmit" && -n "${PULL_NUMBER:-}" ]]; then
  echo "==> Posting staging URL to PR #${PULL_NUMBER}..."
  GH_APP_DIR="/var/run/github-token"
  if [[ -f "${GH_APP_DIR}/app-id" && -f "${GH_APP_DIR}/private-key" && -f "${GH_APP_DIR}/openshift-installation-id" ]]; then
    set +x
    APP_ID=$(cat "${GH_APP_DIR}/app-id")
    PRIVATE_KEY="${GH_APP_DIR}/private-key"
    INSTALL_ID=$(cat "${GH_APP_DIR}/openshift-installation-id")
    NOW=$(date +%s)
    HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    PAYLOAD=$(echo -n "{\"iat\":$((NOW - 60)),\"exp\":$((NOW + 600)),\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "${PRIVATE_KEY}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    GITHUB_TOKEN=$(curl -sf -X POST \
      -H "Authorization: Bearer ${HEADER}.${PAYLOAD}.${SIGNATURE}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
      | jq -r '.token')

    MINUTES=$(( STAGING_TIMEOUT / 60 ))
    COMMENT_BODY=$(jq -n --arg url "${TUNNEL_URL}" --arg min "${MINUTES}" \
      '{body: "### Sippy Staging Environment\n\n**URL:** \($url)\n\nThis environment is built from this PR and will remain available for approximately \($min) minutes."}')

    curl -sf -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/issues/${PULL_NUMBER}/comments" \
      -d "${COMMENT_BODY}" > /dev/null && echo "    Comment posted." || echo "    WARNING: Failed to post comment."
    set -x
  else
    echo "    WARNING: GitHub App credentials not found, skipping PR comment."
  fi
fi

echo "==> Staging environment is live. Sleeping for ${STAGING_TIMEOUT} seconds..."
sleep "${STAGING_TIMEOUT}"

echo "==> Staging timeout reached. Shutting down."
kill "${TUNNEL_PID}" 2>/dev/null || true
kill "${SIPPY_PID}" 2>/dev/null || true
