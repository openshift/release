#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "=== openshift-eng/edge-tooling gh-notifier ==="
echo "Started at $(date -u '+%Y-%m-%d %H:%M UTC')"

# ---------------------------------------------------------------------------
# GitHub App token (same flow as openshift-edge-tooling-ci-monitor-commands.sh)
# xtrace off so credentials are not logged
# ---------------------------------------------------------------------------
set +x

if [[ -f "${GITHUB_APP_ID_PATH}" ]] && [[ -f "${GITHUB_KEY_PATH}" ]]; then
    GH_TOKEN_EXE="${GH_TOKEN_EXE:-/usr/local/bin/gh-token}"
    if [[ ! -x "${GH_TOKEN_EXE}" ]]; then
        echo "ERROR: gh-token not found or not executable at ${GH_TOKEN_EXE} (expected from gh-notifier image build)."
        exit 1
    fi

    if command -v jq >/dev/null 2>&1; then
        GITHUB_TOKEN="$("${GH_TOKEN_EXE}" generate --app-id "$(< "${GITHUB_APP_ID_PATH}")" --key "${GITHUB_KEY_PATH}" | jq -r '.token')"
    else
        GITHUB_TOKEN="$("${GH_TOKEN_EXE}" generate --app-id "$(< "${GITHUB_APP_ID_PATH}")" --key "${GITHUB_KEY_PATH}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"
    fi
    if [[ -z "${GITHUB_TOKEN}" ]] || [[ "${GITHUB_TOKEN}" == "null" ]]; then
        echo "ERROR: Failed to generate GitHub token from App credentials."
        exit 1
    fi
    export GITHUB_TOKEN
    echo "GitHub token generated."
else
    echo "ERROR: GitHub App credentials not found at GITHUB_APP_ID_PATH / GITHUB_KEY_PATH."
    exit 1
fi

# ---------------------------------------------------------------------------
# Slack credential → env (script reads env; do not log values)
# ---------------------------------------------------------------------------
if [[ -n "${SLACK_WEBHOOK_SECRET_FILE:-}" ]] && [[ -f "${SLACK_WEBHOOK_SECRET_FILE}" ]]; then
    SLACK_WEBHOOK_URL="$(<"${SLACK_WEBHOOK_SECRET_FILE}")"
    export SLACK_WEBHOOK_URL
fi

echo "Working directory: ${PWD}"
sleep 3000
GH_NOTIFIER_INVOKE="${GH_NOTIFIER_INVOKE:-python3 gh-notifier/gh-notifier.py}"
bash -c "set -euo pipefail; ${GH_NOTIFIER_INVOKE}"

# ---------------------------------------------------------------------------
# Prow / GCS: publish pr-dashboard.html (ci-operator sets ARTIFACT_DIR)
# ---------------------------------------------------------------------------
cp -f "./gh-notifier/pr-dashboard.html" "${ARTIFACT_DIR}/pr-dashboard.html"
echo "Copied ./gh-notifier/pr-dashboard.html to ${ARTIFACT_DIR}/pr-dashboard.html (job artifacts / GCS)."

