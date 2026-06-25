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

echo "==> Configuring httpd reverse proxy with basic auth..."
HTPASSWD_FILE="/var/run/sippy-staging-htpasswd/htpasswd"
if [[ -f "${HTPASSWD_FILE}" ]]; then
  cat > /tmp/httpd-proxy.conf <<'CONFEOF'
Listen 8081
ServerName localhost
ErrorLog /tmp/httpd-error.log
PidFile /tmp/httpd.pid

LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule authn_core_module modules/mod_authn_core.so
LoadModule authn_file_module modules/mod_authn_file.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_user_module modules/mod_authz_user.so
LoadModule auth_basic_module modules/mod_auth_basic.so
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so
LoadModule unixd_module modules/mod_unixd.so

<Location "/">
  AuthType Basic
  AuthName "Sippy Staging"
  AuthUserFile HTPASSWD_PATH
  Require valid-user
  ProxyPass http://localhost:8080/
  ProxyPassReverse http://localhost:8080/
</Location>
CONFEOF
  sed -i "s|HTPASSWD_PATH|${HTPASSWD_FILE}|" /tmp/httpd-proxy.conf
  httpd -f /tmp/httpd-proxy.conf &
  HTTPD_PID=$!
  PROXY_PORT=8081
  echo "    httpd started on port ${PROXY_PORT}."
else
  echo "    WARNING: htpasswd file not found, running without auth."
  PROXY_PORT=8080
fi

echo "==> Starting cloudflared tunnel..."
cloudflared tunnel --url http://localhost:${PROXY_PORT} > /tmp/cloudflared.log 2>&1 &
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
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Sippy Staging Environment</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 960px; margin: 0 auto; padding: 3rem 2rem; }
  a { color: #0366d6; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .url { font-size: 1.2em; margin: 1rem 0; }
</style>
</head>
<body>
<h2>Sippy Staging Environment</h2>
<p class="url"><strong>URL:</strong> <a href="${TUNNEL_URL}" target="_blank">${TUNNEL_URL}</a></p>
<p>This environment is built from this PR and will remain available for approximately ${MINUTES} minutes.</p>
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

  # --- Post PR comment via pre-generated GitHub token ---
  if [[ "${JOB_TYPE:-}" == "presubmit" && -n "${PULL_NUMBER:-}" ]]; then
    echo "==> Posting staging URL to PR ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}..."
    GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token" 2>/dev/null || true)

    if [[ -z "${GITHUB_TOKEN}" ]]; then
      echo "    WARNING: No GitHub token found in SHARED_DIR, skipping PR comment."
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
  fi
fi

if [[ "${URL_SURFACED}" != "true" ]]; then
  echo "ERROR: Could not surface staging URL via Spyglass or PR comment. Shutting down."
  kill "${HTTPD_PID:-}" 2>/dev/null || true
  kill "${TUNNEL_PID}" 2>/dev/null || true
  kill "${SIPPY_PID}" 2>/dev/null || true
  exit 1
fi

echo "==> Staging environment is live. Sleeping for ${STAGING_TIMEOUT} seconds..."
sleep "${STAGING_TIMEOUT}"

echo "==> Staging timeout reached. Shutting down."
kill "${HTTPD_PID:-}" 2>/dev/null || true
kill "${TUNNEL_PID}" 2>/dev/null || true
kill "${SIPPY_PID}" 2>/dev/null || true
