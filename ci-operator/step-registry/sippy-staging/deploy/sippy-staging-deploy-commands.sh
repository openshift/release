#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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

echo "==> Waiting for sippy to be ready..."
READY=false
for _ in $(seq 1 60); do
  if curl -sf http://localhost:8080/api/releases > /dev/null 2>&1; then
    echo "    Sippy is ready."
    READY=true
    break
  fi
  sleep 5
done

if [[ "${READY}" != "true" ]]; then
  echo "ERROR: Sippy did not become ready in time."
  exit 1
fi

echo "==> Configuring httpd reverse proxy with basic auth..."
HTPASSWD_FILE="/var/run/sippy-staging-htpasswd/htpasswd"
if [[ -f "${HTPASSWD_FILE}" ]]; then
  cat > /tmp/httpd-proxy.conf <<CONFEOF
Listen 8081
ServerName localhost
ErrorLog /tmp/httpd-error.log
PidFile /tmp/httpd.pid

# Core
LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule unixd_module modules/mod_unixd.so
# Basic auth via htpasswd file
LoadModule authn_core_module modules/mod_authn_core.so
LoadModule authn_file_module modules/mod_authn_file.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_user_module modules/mod_authz_user.so
LoadModule auth_basic_module modules/mod_auth_basic.so
# Reverse proxy to sippy
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so

<Location "/">
  AuthType Basic
  AuthName "Sippy Staging"
  AuthUserFile ${HTPASSWD_FILE}
  Require valid-user
  ProxyPass http://localhost:8080/
  ProxyPassReverse http://localhost:8080/
</Location>
CONFEOF
  httpd -f /tmp/httpd-proxy.conf &
  PROXY_PORT=8081
  echo "    httpd started on port ${PROXY_PORT}."
else
  echo "ERROR: htpasswd file not found. Refusing to run without auth."
  exit 1
fi

echo "==> Starting cloudflared tunnel..."
cloudflared tunnel --url http://localhost:${PROXY_PORT} > /tmp/cloudflared.log 2>&1 &

TUNNEL_URL=""
for _ in $(seq 1 12); do
  TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log | head -1 || true)
  [[ -n "${TUNNEL_URL}" ]] && break
  sleep 5
done
MINUTES=$(( STAGING_TIMEOUT / 60 ))
EXPIRES_AT=$(date -u -d "+${STAGING_TIMEOUT} seconds" '+%H:%M UTC')

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
echo "  ${MINUTES} minutes (until ~${EXPIRES_AT})."
echo ""
echo "============================================================"
echo ""

URL_SURFACED=false

if [[ -n "${TUNNEL_URL}" ]]; then
  # --- Upload HTML to GCS for Spyglass visibility ---
  GCS_SA="/tmp/gcs/service-account.json"
  if [[ -f "${GCS_SA}" ]]; then
    echo "==> Uploading staging URL to Spyglass..."
    GCS_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts/staging/sippy-staging-deploy"

    cat > /tmp/custom-link-staging.html <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Sippy Staging Environment</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 960px; margin: 0 auto; padding: 3rem 2rem; color: #fff; }
  a { color: #0366d6; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .url { font-size: 1.2em; margin: 1rem 0; }
</style>
</head>
<body>
<h2>Sippy Staging Environment</h2>
<p class="url"><strong>URL:</strong> <a href="${TUNNEL_URL}" target="_blank">${TUNNEL_URL}</a></p>
<p>This environment is built from this PR and will remain available for approximately ${MINUTES} minutes (until ~${EXPIRES_AT}).</p>
<p>&nbsp;</p>
<p>&nbsp;</p>
<p>&nbsp;</p>
<p>&nbsp;</p>
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

  # --- Post PR comment via gh CLI ---
  echo "==> Posting staging URL to PR ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}..."
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token" 2>/dev/null || true)

  if [[ -z "${GITHUB_TOKEN}" ]]; then
    echo "    WARNING: No GitHub token found in SHARED_DIR, skipping PR comment."
    echo "    (Expected for rehearsal jobs on repos where trt-agent-gh-app is not installed.)"
  else
    COMMENT="### Sippy Staging Environment

**URL:** ${TUNNEL_URL}

This environment is built from this PR and will remain available for approximately ${MINUTES} minutes (until ~${EXPIRES_AT})."

    if GH_TOKEN="${GITHUB_TOKEN}" gh pr comment "${PULL_NUMBER}" \
        --repo "${REPO_OWNER}/${REPO_NAME}" \
        --body "${COMMENT}"; then
      echo "    Comment posted to ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}."
      URL_SURFACED=true
    else
      echo "    WARNING: Failed to post comment."
      echo "    (Expected for rehearsal jobs on repos where trt-agent-gh-app is not installed.)"
    fi
  fi
  $WAS_TRACING && set -x
fi

if [[ "${URL_SURFACED}" != "true" ]]; then
  echo "ERROR: Could not surface staging URL via Spyglass or PR comment."
  exit 1
fi

echo "==> Staging environment is live. Sleeping for ${STAGING_TIMEOUT} seconds..."
sleep "${STAGING_TIMEOUT}"

echo "==> Staging timeout reached. Shutting down."
