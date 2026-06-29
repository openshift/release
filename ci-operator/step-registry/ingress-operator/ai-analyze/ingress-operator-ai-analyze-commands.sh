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

if [[ ! -f "${APP_ID_FILE}" || ! -f "${PRIVATE_KEY}" || ! -f "${INSTALLATION_ID_FILE}" ]]; then
    echo "WARNING: Required GitHub App credentials not found in ${CRED_DIR}"
    echo "Continuing without GitHub authentication (read-only mode)..."
else
    APP_ID=$(cat "${APP_ID_FILE}")
    INSTALLATION_ID=$(cat "${INSTALLATION_ID_FILE}")

    # Disable tracing during token generation to avoid leaking JWT
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x

    NOW=$(date +%s)
    IAT=$((NOW - 60))
    EXP=$((NOW + 600))
    HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "${PRIVATE_KEY}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

    export GITHUB_TOKEN=$(curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 \
        -X POST \
        -H "Authorization: Bearer ${JWT}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")

    if [[ -z "${GITHUB_TOKEN}" ]]; then
        echo "WARNING: Failed to generate GitHub App token."
        echo "Continuing without GitHub authentication (read-only mode)..."
    else
        echo "GitHub App authenticated successfully."
    fi

    $WAS_TRACING && set -x
fi

# Execute Claude Code in non-interactive mode
echo "Running Claude Code CI failure analysis..."
timeout 7200 claude \
    --model "${CLAUDE_MODEL}" \
    --allowedTools "Bash Read Grep Glob WebFetch" \
    --output-format stream-json \
    --max-turns 150 \
    -p "Analyze the test logs and failures in this PR. Identify the root cause and leave a descriptive summary with proposed fixes."
