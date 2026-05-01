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

echo "Working directory: ${PWD}"

# Presubmit and pj-rehearse set PULL_NUMBER: no prow job URL and no Slack
# webhook so rehearsals cannot notify the channel.
# Periodics leave PULL_NUMBER unset and get both.
job_base="https://prow.ci.openshift.org/view/gs/test-platform-results"
html_base="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"
if [[ -z "${PULL_NUMBER:-}" ]]; then
  export PROW_JOB_URL="${job_base}/logs/${JOB_NAME}/${BUILD_ID}"
  export PROW_HTML_URL="${html_base}/logs/${JOB_NAME}/${BUILD_ID}/artifacts/pr-notifier/openshift-edge-tooling-gh-notifier/artifacts/edge-tooling-pr-summary.html"
  if [[ -n "${SLACK_WEBHOOK_SECRET_FILE:-}" ]] && [[ -f "${SLACK_WEBHOOK_SECRET_FILE}" ]]; then
    SLACK_WEBHOOK_URL="$(<"${SLACK_WEBHOOK_SECRET_FILE}")"
    export SLACK_WEBHOOK_URL
  fi
else
  unset PROW_JOB_URL
  unset PROW_HTML_URL
  unset SLACK_WEBHOOK_URL
fi

GH_NOTIFIER_INVOKE="${GH_NOTIFIER_INVOKE:-python3 gh-notifier/gh-notifier.py}"
bash -c "set -euo pipefail; ${GH_NOTIFIER_INVOKE}"

# ---------------------------------------------------------------------------
# Prow / GCS: publish dashboard HTML (ci-operator sets ARTIFACT_DIR).
# Spyglass html lens only picks up paths matching deck's required_files regex
# (see core-services/prow/02_config _config.yaml), e.g. *-summary*.html — same
# idea as openshift-edge-tooling-ci-monitor (edge-ci-monitor-summary.html).
# ---------------------------------------------------------------------------
cp -f "./gh-notifier/pr-dashboard.html" "${ARTIFACT_DIR}/edge-tooling-pr-summary.html"
echo "Copied ./gh-notifier/pr-dashboard.html to ${ARTIFACT_DIR}/edge-tooling-pr-summary.html (Spyglass + GCS)."

