#!/bin/bash
set -euo pipefail

echo "Setting up Google Application Credentials for Vertex AI..."
# Note: The payload agent mounts sa-claude-openshift-ci which has a 'token' key
export GOOGLE_APPLICATION_CREDENTIALS=/var/run/vertex-ai-creds/token

echo "Authenticating as GitHub App..."
CRED_DIR="/var/run/github-app-creds"
APP_ID_FILE="${CRED_DIR}/app-id"
PRIVATE_KEY="${CRED_DIR}/private-key"
INSTALLATION_ID_FILE="${CRED_DIR}/openshift-installation-id"

# Disable tracing during token generation to avoid leaking JWT
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

GITHUB_TOKEN=""
if APP_ID=$(cat "${APP_ID_FILE}" 2>/dev/null) \
    && INSTALLATION_ID=$(cat "${INSTALLATION_ID_FILE}" 2>/dev/null) \
    && NOW=$(date +%s); then
    IAT=$((NOW - 60))
    EXP=$((NOW + 600))
    if HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n') \
        && PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n') \
        && SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "${PRIVATE_KEY}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n' 2>/dev/null); then
        JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"
        TOKEN_RESPONSE=$(curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 \
            -X POST \
            -H "Authorization: Bearer ${JWT}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" 2>/dev/null) || TOKEN_RESPONSE=""
        if [[ -n "${TOKEN_RESPONSE}" ]]; then
            GITHUB_TOKEN=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" <<<"${TOKEN_RESPONSE}") || GITHUB_TOKEN=""
        fi
    fi
fi
export GITHUB_TOKEN

if [[ -z "${GITHUB_TOKEN}" ]]; then
    echo "WARNING: Failed to generate GitHub App token (credentials may be missing or invalid)."
    echo "Continuing without GitHub authentication (read-only mode)..."
else
    echo "GitHub App authenticated successfully."
fi

$WAS_TRACING && set -x

# Execute Claude Code in non-interactive mode
echo "Running Claude Code CI failure analysis..."
timeout 7200 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "Read Grep Glob WebFetch" \
    --verbose \
    --output-format stream-json \
    --max-turns 150 \
    -p "Analyze the test logs for this specific failed Prow job: https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/openshift_cluster-ingress-operator/1487/pull-ci-openshift-cluster-ingress-operator-release-4.16-e2e-hypershift/2071913985023676416. Identify the root cause and leave a descriptive summary with proposed fixes."
