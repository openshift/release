#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export GITHUB_USER GITHUB_TOKEN MY_GITHUB_ORG DEFAULT_QUAY_ORG DEFAULT_QUAY_ORG_TOKEN QUAY_TOKEN QUAY_E2E_ORGANIZATION

GITHUB_USER=""
GITHUB_TOKEN=""
MY_GITHUB_ORG="redhat-appstudio-qe"
# Don't set E2E_APPLICATIONS_NAMESPACE - let framework create unique namespace
DEFAULT_QUAY_ORG="redhat-appstudio-qe"
QUAY_E2E_ORGANIZATION="redhat-appstudio-qe"
DEFAULT_QUAY_ORG_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/default-quay-org-token)
QUAY_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/quay-token)

# Select GitHub user with highest rate limit remaining
PREVIOUS_RATE_REMAINING=0
IFS=',' read -r -a GITHUB_ACCOUNTS_ARRAY <<< "$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/github_accounts)"
for account in "${GITHUB_ACCOUNTS_ARRAY[@]}"
do :
    IFS=':' read -r -a GITHUB_USERNAME_ARRAY <<< "$account"

    if GH_RATE_REMAINING=$(curl --fail --show-error --silent --max-time 10 \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_USERNAME_ARRAY[1]}" \
        https://api.github.com/rate_limit | jq -er ".rate.remaining"); then
        echo -e "[INFO ] user: ${GITHUB_USERNAME_ARRAY[0]} with rate limit remaining $GH_RATE_REMAINING"
        if [[ "${GH_RATE_REMAINING}" -ge "${PREVIOUS_RATE_REMAINING}" ]];then
            GITHUB_USER="${GITHUB_USERNAME_ARRAY[0]}"
            GITHUB_TOKEN="${GITHUB_USERNAME_ARRAY[1]}"
        fi
        PREVIOUS_RATE_REMAINING="${GH_RATE_REMAINING}"
    else
        echo -e "[WARN ] Failed to get rate limit for user: ${GITHUB_USERNAME_ARRAY[0]}"
    fi
done

if [[ -z "${GITHUB_USER}" ]] || [[ -z "${GITHUB_TOKEN}" ]]; then
    echo "ERROR: No valid GitHub credentials found. All accounts failed authentication."
    exit 1
fi

echo -e "[INFO] Start tests with user: ${GITHUB_USER}"

# Not running with upstream dependencies
unset TEST_ENVIRONMENT

git config --global user.name "redhat-appstudio-qe-bot"
git config --global user.email redhat-appstudio-qe-bot@redhat.com

mkdir -p "${HOME}/creds"
GIT_CREDS_PATH="${HOME}/creds/file"
git config --global credential.helper "store --file ${GIT_CREDS_PATH}"
echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" > "${GIT_CREDS_PATH}"

cd "$(mktemp -d)"

# Clone konflux-ci/konflux-ci repository
KONFLUX_REPO="${KONFLUX_REPO:-konflux-ci/konflux-ci}"
KONFLUX_REF="${KONFLUX_REF:-main}"

# Handle Gangway API override - derive KONFLUX_REF from OPERATOR_IMAGE tag
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_OPERATOR_IMAGE:-}" ]]; then
    KONFLUX_REF="${MULTISTAGE_PARAM_OVERRIDE_OPERATOR_IMAGE##*:}"
    echo "Derived KONFLUX_REF=${KONFLUX_REF} from Gangway override"
fi

echo "Cloning ${KONFLUX_REPO} at ref ${KONFLUX_REF}..."
git clone --origin upstream --branch main "https://${GITHUB_TOKEN}@github.com/${KONFLUX_REPO}.git" .

# Checkout specific ref if not main
if [[ "${KONFLUX_REF}" != "main" ]]; then
    echo "Checking out KONFLUX_REF: ${KONFLUX_REF}"
    git fetch --tags origin 2>/dev/null || true
    git fetch --unshallow origin 2>/dev/null || true
    git checkout "${KONFLUX_REF}" || {
        echo "ERROR: Failed to checkout ${KONFLUX_REF}"
        exit 1
    }
    echo "Successfully checked out ${KONFLUX_REF}"
fi

# Create konflux-cli namespace and ConfigMap for setup-release.sh
# The conformance tests expect to download this script from a ConfigMap
echo "Creating konflux-cli namespace and setup-release ConfigMap..."
oc create namespace konflux-cli --dry-run=client -o yaml | oc apply -f -

oc create configmap setup-release \
    --from-file=setup-release.sh=./operator/upstream-kustomizations/cli/setup-release.sh \
    -n konflux-cli \
    --dry-run=client -o yaml | oc apply -f -

echo "ConfigMap created successfully"

# Verify image-controller is running
echo "Checking image-controller status..."
oc get deployment -n image-controller image-controller 2>/dev/null || echo "WARN: image-controller deployment not found"

# Create pipelines-as-code-secret for GitHub App authentication
echo "Creating pipelines-as-code-secret in openshift-pipelines namespace..."
export E2E_PAC_GITHUB_APP_ID E2E_PAC_GITHUB_APP_PRIVATE_KEY PAC_GITHUB_APP_WEBHOOK_SECRET
E2E_PAC_GITHUB_APP_ID=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pac-github-app-id)
E2E_PAC_GITHUB_APP_PRIVATE_KEY=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pac-github-app-private-key)
PAC_GITHUB_APP_WEBHOOK_SECRET=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pac-github-app-webhook-secret)

oc create secret generic pipelines-as-code-secret \
    -n openshift-pipelines \
    --from-literal=github-application-id="${E2E_PAC_GITHUB_APP_ID}" \
    --from-literal=github-private-key="${E2E_PAC_GITHUB_APP_PRIVATE_KEY}" \
    --from-literal=webhook.secret="${PAC_GITHUB_APP_WEBHOOK_SECRET}" \
    --dry-run=client -o yaml | oc apply -f -

echo "pipelines-as-code-secret created successfully"

# Build ginkgo label filter args
LABEL_ARGS=()
if [[ -n "${GINKGO_LABEL_FILTER:-}" ]]; then
    LABEL_ARGS+=("-ginkgo.label-filter=${GINKGO_LABEL_FILTER}")
fi

# Run conformance tests
echo "Running conformance tests from test/go-tests..."
cd test/go-tests
go test -mod=mod ./tests/conformance \
    -v \
    -timeout "${GINKGO_TEST_TIMEOUT:-30m}" \
    -ginkgo.vv \
    ${LABEL_ARGS[@]+"${LABEL_ARGS[@]}"}
