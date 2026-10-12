#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Load credentials
DEFAULT_QUAY_ORG_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/default-quay-org-token)
QUAY_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/quay-token)

# Select GitHub account with best rate limit
GITHUB_ACCOUNTS=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/github_accounts)
GITHUB_USER=""
GITHUB_TOKEN=""
PREVIOUS_RATE=0

IFS=',' read -r -a ACCOUNTS <<< "$GITHUB_ACCOUNTS"
for account in "${ACCOUNTS[@]}"; do
    IFS=':' read -r -a CREDS <<< "$account"
    if RATE=$(curl --fail --silent --max-time 10 \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${CREDS[1]}" \
        https://api.github.com/rate_limit | jq -er ".rate.remaining"); then
        echo "[INFO] GitHub user ${CREDS[0]}: ${RATE} requests remaining"
        if [[ "${RATE}" -ge "${PREVIOUS_RATE}" ]]; then
            GITHUB_USER="${CREDS[0]}"
            GITHUB_TOKEN="${CREDS[1]}"
            PREVIOUS_RATE="${RATE}"
        fi
    else
        echo "[WARN] Failed to get rate limit for user: ${CREDS[0]}"
    fi
done

if [[ -z "${GITHUB_USER}" ]]; then
    echo "ERROR: No valid GitHub credentials found"
    exit 1
fi

echo "[INFO] Using GitHub user: ${GITHUB_USER}"

# Export environment for tests
export GITHUB_USER GITHUB_TOKEN
export MY_GITHUB_ORG="redhat-appstudio-qe"
export E2E_APPLICATIONS_NAMESPACE="user-ns1"
export DEFAULT_QUAY_ORG="redhat-appstudio-qe"
export DEFAULT_QUAY_ORG_TOKEN
export QUAY_TOKEN
export QUAY_E2E_ORGANIZATION="redhat-appstudio-qe"

# Configure git
git config --global user.name "redhat-appstudio-qe-bot"
git config --global user.email redhat-appstudio-qe-bot@redhat.com
mkdir -p "${HOME}/creds"
GIT_CREDS_PATH="${HOME}/creds/file"
git config --global credential.helper "store --file ${GIT_CREDS_PATH}"
echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" > "${GIT_CREDS_PATH}"

# Clone konflux-ci repository
cd "$(mktemp -d)"
KONFLUX_REPO="${KONFLUX_REPO:-konflux-ci/konflux-ci}"
KONFLUX_REF="${KONFLUX_REF:-main}"

# Override ref if Gangway operator image is provided
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_OPERATOR_IMAGE:-}" ]]; then
    KONFLUX_REF="${MULTISTAGE_PARAM_OVERRIDE_OPERATOR_IMAGE##*:}"
    echo "[INFO] Using KONFLUX_REF=${KONFLUX_REF} from Gangway override"
fi

echo "[INFO] Cloning ${KONFLUX_REPO} at ${KONFLUX_REF}..."
git clone --origin upstream --branch main "https://${GITHUB_TOKEN}@github.com/${KONFLUX_REPO}.git" .

if [[ "${KONFLUX_REF}" != "main" ]]; then
    git fetch --tags origin 2>/dev/null || git fetch --unshallow origin 2>/dev/null || true
    git checkout "${KONFLUX_REF}" || {
        echo "ERROR: Failed to checkout ${KONFLUX_REF}"
        exit 1
    }
fi

# Deploy test resources (creates user-ns1, user-ns2 with LocalQueue, ServiceAccounts, RoleBindings)
echo "[INFO] Deploying test resources..."
SKIP_SAMPLE_COMPONENTS="true" ./deploy-test-resources.sh

# Verify tenant namespace setup
if ! oc get localqueue pipelines-queue -n "${E2E_APPLICATIONS_NAMESPACE}" &>/dev/null; then
    echo "ERROR: LocalQueue not found in ${E2E_APPLICATIONS_NAMESPACE}"
    exit 1
fi

# Create konflux-cli namespace with setup-release ConfigMap
oc create namespace konflux-cli --dry-run=client -o yaml | oc apply -f -
oc create configmap setup-release \
    --from-file=setup-release.sh=./operator/upstream-kustomizations/cli/setup-release.sh \
    -n konflux-cli \
    --dry-run=client -o yaml | oc apply -f -

# Run conformance tests
LABEL_ARGS=()
if [[ -n "${GINKGO_LABEL_FILTER:-}" ]]; then
    LABEL_ARGS+=("-ginkgo.label-filter=${GINKGO_LABEL_FILTER}")
fi

echo "[INFO] Running conformance tests..."
cd test/go-tests
go test -mod=mod ./tests/conformance \
    -v \
    -timeout "${GINKGO_TEST_TIMEOUT:-30m}" \
    -ginkgo.vv \
    ${LABEL_ARGS[@]+"${LABEL_ARGS[@]}"}
