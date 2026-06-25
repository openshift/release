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

MINUTES=$(( STAGING_TIMEOUT / 60 ))
URL_SURFACED=false

if [[ -n "${TUNNEL_URL}" ]]; then
  # --- Upload HTML to GCS for Spyglass visibility ---
  GCS_SA="/tmp/gcs/service-account.json"
  if [[ -f "${GCS_SA}" ]]; then
    echo "==> Uploading staging URL to Spyglass..."
    if [[ "${JOB_TYPE:-}" == "presubmit" && -n "${PULL_NUMBER:-}" ]]; then
      GCS_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts/staging/sippy-staging-deploy"
    else
      GCS_PATH="logs/${JOB_NAME}/${BUILD_ID}/artifacts/staging/sippy-staging-deploy"
    fi

    cat > /tmp/custom-link-staging.html <<HTMLEOF
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Sippy Staging</title></head>
<body style="font-family: system-ui, sans-serif; padding: 20px;">
<h2>Sippy Staging Environment</h2>
<p><strong>URL:</strong> <a href="${TUNNEL_URL}" target="_blank">${TUNNEL_URL}</a></p>
<p>This environment is built from this PR and will remain available for approximately ${MINUTES} minutes.</p>
</body>
</html>
HTMLEOF

    if gcloud auth activate-service-account --quiet --key-file "${GCS_SA}" 2>/dev/null && \
       gsutil -q cp /tmp/custom-link-staging.html "gs://test-platform-results/${GCS_PATH}/custom-link-staging.html"; then
      echo "    Uploaded to Spyglass."
      URL_SURFACED=true
    else
      echo "    WARNING: Failed to upload to GCS."
    fi
  else
    echo "==> GCS credentials not found, skipping Spyglass upload."
  fi

  # --- Post PR comment via GitHub App ---
  if [[ "${JOB_TYPE:-}" == "presubmit" && -n "${PULL_NUMBER:-}" ]]; then
    echo "==> Posting staging URL to PR ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}..."
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
      TOKEN_RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer ${HEADER}.${PAYLOAD}.${SIGNATURE}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" 2>&1)
      GITHUB_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.token // empty')
      set -euo pipefail

      if [[ -z "${GITHUB_TOKEN}" ]]; then
        echo "    WARNING: Failed to generate GitHub token, skipping PR comment."
        echo "    (Expected for rehearsal jobs on repos where trt-agent-gh-app is not installed.)"
      else
        COMMENT_BODY=$(jq -n --arg url "${TUNNEL_URL}" --arg min "${MINUTES}" \
          '{body: "### Sippy Staging Environment\n\n**URL:** \($url)\n\nThis environment is built from this PR and will remain available for approximately \($min) minutes."}')
        COMMENT_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
          -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/issues/${PULL_NUMBER}/comments" \
          -d "${COMMENT_BODY}" 2>&1)
        HTTP_CODE=$(echo "${COMMENT_RESPONSE}" | tail -1)
        if [[ "${HTTP_CODE}" == "201" ]]; then
          echo "    Comment posted to ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}."
          URL_SURFACED=true
        else
          echo "    WARNING: Failed to post comment (HTTP ${HTTP_CODE})."
          echo "    (Expected for rehearsal jobs on repos where trt-agent-gh-app is not installed.)"
        fi
      fi
    else
      echo "    WARNING: GitHub App credentials not found, skipping PR comment."
    fi
  fi
fi

if [[ "${URL_SURFACED}" != "true" ]]; then
  echo "ERROR: Could not surface staging URL via Spyglass or PR comment. Shutting down."
  kill "${TUNNEL_PID}" 2>/dev/null || true
  kill "${SIPPY_PID}" 2>/dev/null || true
  exit 1
fi

echo "==> Staging environment is live. Sleeping for ${STAGING_TIMEOUT} seconds..."
sleep "${STAGING_TIMEOUT}"

echo "==> Staging timeout reached. Shutting down."
kill "${TUNNEL_PID}" 2>/dev/null || true
kill "${SIPPY_PID}" 2>/dev/null || true
