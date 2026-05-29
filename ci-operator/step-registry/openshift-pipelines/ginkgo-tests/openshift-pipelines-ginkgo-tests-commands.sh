#!/bin/bash
set -euo pipefail; shopt -s inherit_errexit

# Verify required tools are available
command -v ginkgo >/dev/null 2>&1 || { echo "ERROR: ginkgo not found in PATH"; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found in PATH"; exit 1; }

# Login to the cluster
if [ -s "${KUBECONFIG:-}" ]; then
    oc whoami
else
    # Login for ROSA & Hypershift platforms
    # Disable tracing to avoid logging credentials
    set +x
    eval "$(cat "${SHARED_DIR}/api.login")"
    set -euo pipefail
fi

cd /tmp/release-tests-ginkgo

# Load e2e secrets from vault-synced secret (aws-osp-qe in test-credentials)
# Disable tracing to avoid logging secret values
set +x
SECRET_DIR=/var/run/openshift-pipelines/osp-ci-secrets
for var in GITHUB_TOKEN GITLAB_TOKEN GITLAB_WEBHOOK_TOKEN GITLAB_GROUP_NAMESPACE GITLAB_PROJECT_ID; do
    [ -f "${SECRET_DIR}/${var}" ] && export "${var}=$(cat "${SECRET_DIR}/${var}")"
done
set -euo pipefail

# Run OpenShift Pipelines e2e tests using Ginkgo label filter
# Disable tracing to avoid logging cluster URLs in CI logs
set +x
CONSOLE_URL="$(oc whoami --show-console)"
API_URL="$(oc whoami --show-server)"
export CONSOLE_URL API_URL
echo "Running Ginkgo tests with label-filter=${GINKGO_LABEL_FILTER:-e2e && !disconnected} timeout=${TEST_TIMEOUT:-4h} procs=${GINKGO_PROCS:-4}"
set -x
ginkgo run \
    --label-filter="${GINKGO_LABEL_FILTER:-e2e && !disconnected}" \
    --timeout="${TEST_TIMEOUT:-4h}" \
    --procs="${GINKGO_PROCS:-4}" \
    --junit-report="${ARTIFACT_DIR}/junit-openshift-pipelines-ginkgo-tests.xml" \
    --output-dir="${ARTIFACT_DIR}" \
    -v \
    ./tests/...
