#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Load required credentials
DEFAULT_QUAY_ORG=redhat-appstudio-qe
DEFAULT_QUAY_ORG_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/default-quay-org-token)
QUAY_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/quay-token)
E2E_PAC_GITHUB_APP_ID=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pac-github-app-id)
E2E_PAC_GITHUB_APP_PRIVATE_KEY=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pac-github-app-private-key)
PAC_GITHUB_APP_WEBHOOK_SECRET=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pac-github-app-webhook-secret)
SMEE_CHANNEL=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/smee-channel)
QE_SPRAYPROXY_HOST=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/qe-sprayproxy-host)
QE_SPRAYPROXY_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/qe-sprayproxy-token)

# Select GitHub account with best rate limit
GITHUB_ACCOUNTS=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/github_accounts)
GITHUB_USER=""
GITHUB_TOKEN=""
PREVIOUS_RATE=0

IFS=',' read -r -a ACCOUNTS <<< "$GITHUB_ACCOUNTS"
for account in "${ACCOUNTS[@]}"; do
    IFS=':' read -r -a CREDS <<< "$account"
    RATE=$(curl -s -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${CREDS[1]}" \
        https://api.github.com/rate_limit | jq ".rate.remaining")
    echo "[INFO] GitHub user ${CREDS[0]}: ${RATE} requests remaining"
    if [[ "${RATE}" -ge "${PREVIOUS_RATE}" ]]; then
        GITHUB_USER="${CREDS[0]}"
        GITHUB_TOKEN="${CREDS[1]}"
        PREVIOUS_RATE="${RATE}"
    fi
done

echo "[INFO] Using GitHub user: ${GITHUB_USER}"

# Cluster login
yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' $KUBECONFIG
export OPENSHIFT_API
OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"

export OPENSHIFT_PASSWORD
if [[ -s "$KUBEADMIN_PASSWORD_FILE" ]]; then
    OPENSHIFT_PASSWORD="$(cat $KUBEADMIN_PASSWORD_FILE)"
elif [[ -s "${SHARED_DIR}/kubeadmin-password" ]]; then
    OPENSHIFT_PASSWORD="$(cat ${SHARED_DIR}/kubeadmin-password)"
else
    echo "ERROR: Kubeadmin password file not found"
    exit 1
fi

timeout --foreground 5m bash <<- "EOF"
    while ! oc login "$OPENSHIFT_API" -u "kubeadmin" -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
        sleep 20
    done
EOF
if [ $? -ne 0 ]; then
    echo "ERROR: Timed out waiting for cluster login"
    exit 1
fi

# Configure git credentials
git config --global user.name "redhat-appstudio-qe-bot"
git config --global user.email redhat-appstudio-qe-bot@redhat.com
mkdir -p "${HOME}/creds"
GIT_CREDS_PATH="${HOME}/creds/file"
git config --global credential.helper "store --file ${GIT_CREDS_PATH}"
echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" > "${GIT_CREDS_PATH}"

# Clone infra-deployments
INFRA_DIR="$(mktemp -d)/infra-deployments"
echo "[INFO] Cloning infra-deployments..."
git clone --origin upstream --branch main \
    "https://${GITHUB_TOKEN}@github.com/redhat-appstudio/infra-deployments.git" "${INFRA_DIR}"
cd "${INFRA_DIR}"

git remote add origin "https://github.com/redhat-appstudio-qe/infra-deployments.git" || true
git pull --rebase upstream main

# Mark master nodes as schedulable (for small clusters)
oc patch scheduler cluster --type=merge -p '{"spec":{"mastersSchedulable":true}}' 2>&1 || \
    echo "[WARN] Could not modify scheduler (might be HyperShift cluster)"

# Export environment for preview mode
export MY_GITHUB_ORG="redhat-appstudio-qe"
export MY_GITHUB_TOKEN="${GITHUB_TOKEN}"
export MY_GIT_FORK_REMOTE="origin"
TEST_BRANCH_ID="$(head /dev/urandom | tr -dc a-z0-9 | head -c 4)"
export TEST_BRANCH_ID
export QUAY_TOKEN
export IMAGE_CONTROLLER_QUAY_ORG="${DEFAULT_QUAY_ORG}"
export IMAGE_CONTROLLER_QUAY_TOKEN="${DEFAULT_QUAY_ORG_TOKEN}"
export BUILD_SERVICE_IMAGE_TAG_EXPIRATION="5d"
export PAC_GITHUB_APP_ID="${E2E_PAC_GITHUB_APP_ID}"
export PAC_GITHUB_APP_PRIVATE_KEY="${E2E_PAC_GITHUB_APP_PRIVATE_KEY}"
export PAC_GITHUB_APP_WEBHOOK_SECRET
export SMEE_CHANNEL

# Run bootstrap
echo "[INFO] Running bootstrap-cluster.sh in preview mode..."
./hack/bootstrap-cluster.sh preview

# Create e2e-secrets/quay-repository secret
echo "[INFO] Creating e2e-secrets/quay-repository secret..."
TEMP_DOCKERCONFIG=$(mktemp)
echo "${QUAY_TOKEN}" | base64 -d > "${TEMP_DOCKERCONFIG}"
oc create namespace e2e-secrets --dry-run=client -o yaml | oc apply -f -
oc create secret docker-registry quay-repository \
    -n e2e-secrets \
    --from-file=.dockerconfigjson="${TEMP_DOCKERCONFIG}" \
    --dry-run=client -o yaml | oc apply -f -
rm -f "${TEMP_DOCKERCONFIG}"

# Register PAC route with SprayProxy
echo "[INFO] Registering PAC server with SprayProxy..."
PAC_ROUTE=$(oc get route pipelines-as-code-controller -n openshift-pipelines -o jsonpath='{.spec.host}')
if [[ -z "${PAC_ROUTE}" ]]; then
    echo "ERROR: PAC route not found"
    exit 1
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${QE_SPRAYPROXY_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"https://${PAC_ROUTE}\"}" \
    "${QE_SPRAYPROXY_HOST}/backends")

if [[ "${HTTP_CODE}" =~ ^(200|201|302)$ ]]; then
    echo "[INFO] Successfully registered with SprayProxy (HTTP ${HTTP_CODE})"
else
    echo "ERROR: Failed to register with SprayProxy (HTTP ${HTTP_CODE})"
    exit 1
fi

echo "[INFO] Konflux installation complete!"
