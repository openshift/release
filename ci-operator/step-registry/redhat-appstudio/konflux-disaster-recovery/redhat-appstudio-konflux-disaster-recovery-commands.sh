#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=$PATH:/tmp/bin
mkdir -p /tmp/bin

export DEFAULT_QUAY_ORG DEFAULT_QUAY_ORG_TOKEN GITHUB_USER GITHUB_TOKEN QUAY_TOKEN QUAY_OAUTH_USER QUAY_OAUTH_TOKEN OPENSHIFT_API OPENSHIFT_USERNAME OPENSHIFT_PASSWORD \
    GITHUB_ACCOUNTS_ARRAY PREVIOUS_RATE_REMAINING GITHUB_USERNAME_ARRAY GH_RATE_REMAINING PYXIS_STAGE_KEY PYXIS_STAGE_CERT OFFLINE_TOKEN TOOLCHAIN_API_URL KEYLOAK_URL EXODUS_PROD_KEY EXODUS_PROD_CERT CGW_USERNAME CGW_TOKEN REL_IMAGE_CONTROLLER_QUAY_ORG REL_IMAGE_CONTROLLER_QUAY_TOKEN RELEASE_PUBLIC_KEY BYOC_KUBECONFIG GITHUB_TOKENS_LIST \
    QE_SPRAYPROXY_HOST QE_SPRAYPROXY_TOKEN E2E_PAC_GITHUB_APP_ID E2E_PAC_GITHUB_APP_PRIVATE_KEY PAC_GITHUB_APP_WEBHOOK_SECRET PAC_GITLAB_TOKEN PAC_GITLAB_URL GITLAB_PROJECT_ID \
    GITLAB_BOT_TOKEN RELEASE_CATALOG_TA_QUAY_TOKEN SMEE_CHANNEL CODEBERG_BOT_TOKEN

DEFAULT_QUAY_ORG=redhat-appstudio-qe
DEFAULT_QUAY_ORG_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/default-quay-org-token)
GITHUB_USER=""
GITHUB_TOKEN=""
GITHUB_TOKENS_LIST="$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/github_accounts)"
QUAY_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/quay-token)
QUAY_OAUTH_USER=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/quay-oauth-user)
QUAY_OAUTH_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/quay-oauth-token)
PYXIS_STAGE_KEY=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pyxis-stage-key)
PYXIS_STAGE_CERT=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pyxis-stage-cert)
OFFLINE_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/stage_offline_token)
TOOLCHAIN_API_URL=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/stage_toolchain_api_url)
KEYLOAK_URL=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/stage_keyloak_url)
EXODUS_PROD_KEY=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/exodus_prod_key)
EXODUS_PROD_CERT=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/exodus_prod_cert)
CGW_USERNAME=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/cgw_username)
CGW_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/cgw_token)
REL_IMAGE_CONTROLLER_QUAY_ORG=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/release_image_controller_quay_org)
REL_IMAGE_CONTROLLER_QUAY_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/release_image_controller_quay_token)
RELEASE_PUBLIC_KEY=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/release_public_key)
OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"
OPENSHIFT_USERNAME="kubeadmin"
PREVIOUS_RATE_REMAINING=0
QE_SPRAYPROXY_HOST=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/qe-sprayproxy-host)
QE_SPRAYPROXY_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/qe-sprayproxy-token)
E2E_PAC_GITHUB_APP_ID=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pac-github-app-id)
E2E_PAC_GITHUB_APP_PRIVATE_KEY=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pac-github-app-private-key)
PAC_GITHUB_APP_WEBHOOK_SECRET=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pac-github-app-webhook-secret)
PAC_GITLAB_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pac-gitlab-token)
PAC_GITLAB_URL=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/pac-gitlab-url)
GITLAB_PROJECT_ID=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/gitlab-project-id)
GITLAB_BOT_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/gitlab-bot-token)
RELEASE_CATALOG_TA_QUAY_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/release-catalog-ta-quay-token)
SMEE_CHANNEL=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/smee-channel)
CODEBERG_BOT_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/codeberg-bot-token)
DR_TIMEOUT=185m
DR_LABEL="disaster-recovery"

# Install velero CLI — required by DR tests for RestoreMethodVeleroCLI.
# Match the version deployed by OADP in the target cluster.
VELERO_VERSION="${VELERO_VERSION:-v1.14.1}"
echo "[INFO] Installing velero CLI ${VELERO_VERSION}"
VELERO_TMP_DIR="$(mktemp -d)"
curl -fsSL "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz" \
    | tar xz -C "$VELERO_TMP_DIR"
cp "${VELERO_TMP_DIR}/velero-${VELERO_VERSION}-linux-amd64/velero" /usr/local/bin/velero
chmod +x /usr/local/bin/velero
velero version --client-only

# user stored: username:token,username:token
IFS=',' read -r -a GITHUB_ACCOUNTS_ARRAY <<< "$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/github_accounts)"
for account in "${GITHUB_ACCOUNTS_ARRAY[@]}"
do :
    IFS=':' read -r -a GITHUB_USERNAME_ARRAY <<< "$account"

    GH_RATE_REMAINING=$(curl -s \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_USERNAME_ARRAY[1]}"\
    https://api.github.com/rate_limit | jq ".rate.remaining")

    echo -e "[INFO ] user: ${GITHUB_USERNAME_ARRAY[0]} with rate limit remaining $GH_RATE_REMAINING"
    if [[ "${GH_RATE_REMAINING}" -ge "${PREVIOUS_RATE_REMAINING}" ]];then
        GITHUB_USER="${GITHUB_USERNAME_ARRAY[0]}"
        GITHUB_TOKEN="${GITHUB_USERNAME_ARRAY[1]}"
    fi
    PREVIOUS_RATE_REMAINING="${GH_RATE_REMAINING}"
done

echo -e "[INFO] Start tests with user: ${GITHUB_USER}"

yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' $KUBECONFIG
if [[ -s "$KUBEADMIN_PASSWORD_FILE" ]]; then
    OPENSHIFT_PASSWORD="$(cat $KUBEADMIN_PASSWORD_FILE)"
elif [[ -s "${SHARED_DIR}/kubeadmin-password" ]]; then
    # Recommendation from hypershift qe team in slack channel..
    OPENSHIFT_PASSWORD="$(cat ${SHARED_DIR}/kubeadmin-password)"
else
    echo "Kubeadmin password file is empty... Aborting job"
    exit 1
fi

timeout --foreground 5m bash  <<- "EOF"
    while ! oc login "$OPENSHIFT_API" -u "$OPENSHIFT_USERNAME" -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            sleep 20
    done
EOF
if [ $? -ne 0 ]; then
	echo "Timed out waiting for login"
	exit 1
fi

# Define a new environment for BYOC pointing to a kubeconfig with token. RHTAP environments only supports kubeconfig with token:
# See: https://issues.redhat.com/browse/GITOPSRVCE-554
BYOC_KUBECONFIG="/tmp/token-kubeconfig"
cp "$KUBECONFIG" "$BYOC_KUBECONFIG"
if [[ -s "$BYOC_KUBECONFIG" ]]; then
    echo -e "byoc kubeconfig exists!"
else
    echo "Kubeconfig not exists in $BYOC_KUBECONFIG... Aborting job"
    exit 1
fi

git config --global user.name "redhat-appstudio-qe-bot"
git config --global user.email redhat-appstudio-qe-bot@redhat.com

mkdir -p "${HOME}/creds"
GIT_CREDS_PATH="${HOME}/creds/file"
git config --global credential.helper "store --file ${GIT_CREDS_PATH}"
echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" > "${GIT_CREDS_PATH}"

# Set UPGRADE_BRANCH and UPGRADE_FORK_ORGANIZATION for the backwards-compat
# DR test's Konflux upgrade phase (performKonfluxUpgrade).
export UPGRADE_BRANCH UPGRADE_FORK_ORGANIZATION

if [[ "${REPO_NAME:-}" == "infra-deployments" && -n "${PULL_NUMBER:-}" ]]; then
    PR_JSON=$(curl -sf -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        "https://api.github.com/repos/redhat-appstudio/infra-deployments/pulls/${PULL_NUMBER}")
    UPGRADE_BRANCH=$(echo "$PR_JSON" | jq -r '.head.ref // empty')
    REPO_URL=$(echo "$PR_JSON" | jq -r '.head.repo.html_url // empty')
    if [[ -z "$UPGRADE_BRANCH" || -z "$REPO_URL" ]]; then
        echo "[ERROR] Failed to resolve PR head ref/repo for PR #${PULL_NUMBER}"
        exit 1
    fi
    UPGRADE_FORK_ORGANIZATION=$(echo "$REPO_URL" | sed 's|https://github.com/||' | sed 's|/infra-deployments||')
else
    UPGRADE_BRANCH=main
    UPGRADE_FORK_ORGANIZATION=redhat-appstudio
fi

echo "[INFO] UPGRADE_BRANCH: $UPGRADE_BRANCH"
echo "[INFO] UPGRADE_FORK_ORGANIZATION: $UPGRADE_FORK_ORGANIZATION"

# Clone infra-deployments for DR test code
# TODO: revert to upstream/main once DR test code is stable
INFRA_DIR="/tmp/infra-deployments"
git clone --branch K-2236-dr-debug "https://github.com/meyrevived/infra-deployments.git" "$INFRA_DIR"

# The clone is from a fork — add upstream so performKonfluxUpgrade can merge
# remotes/upstream/main during the upgrade phase.
git -C "$INFRA_DIR" remote add upstream https://github.com/redhat-appstudio/infra-deployments.git
git -C "$INFRA_DIR" fetch upstream

# Add the QE fork remote (same repo the install step pushed the preview branch to).
# performKonfluxUpgrade pushes merged changes here so ArgoCD picks them up.
git -C "$INFRA_DIR" remote add qe https://github.com/redhat-appstudio-qe/infra-deployments.git
git -C "$INFRA_DIR" fetch qe

# Discover the preview branch ArgoCD is watching. The install step created a
# preview-* branch and configured ArgoCD's all-application-sets to track it.
export ARGO_TARGET_REVISION
ARGO_TARGET_REVISION=$(oc get applications.argoproj.io all-application-sets \
    -n openshift-gitops \
    -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || echo "")
echo "[INFO] ARGO_TARGET_REVISION: ${ARGO_TARGET_REVISION:-<not found>}"

# If this is an infra-deployments PR, merge the PR changes
if [[ "${REPO_NAME:-}" == "infra-deployments" && -n "${PULL_NUMBER:-}" ]]; then
    pushd "$INFRA_DIR"
    # TODO: Once this prow job is completely successful, this needs to switch back to fetch from origin
    git fetch upstream "refs/pull/${PULL_NUMBER}/head"
    git merge --no-edit FETCH_HEAD
    popd
fi

# Export INFRA_DEPLOYMENTS_DIR so performKonfluxUpgrade can find the clone.
# Ginkgo runs the test binary from the package directory, so relative paths
# like ./tmp/infra-deployments won't resolve correctly.
export INFRA_DEPLOYMENTS_DIR="$INFRA_DIR"

# Create relative path symlink expected by performKonfluxUpgrade.
# Go code (dr_backwards_compat.go:183) opens "./tmp/infra-deployments" relative
# to ginkgo's CWD (the test suite directory). Symlink resolves it to the clone.
mkdir -p "${INFRA_DIR}/tests/disaster-recovery/tmp"
ln -sf "$INFRA_DIR" "${INFRA_DIR}/tests/disaster-recovery/tmp/infra-deployments"
echo "[INFO] Symlink: ${INFRA_DIR}/tests/disaster-recovery/tmp/infra-deployments -> ${INFRA_DIR}"

# Point ginkgo at the infra-deployments test directory
export E2E_BIN_PATH="${INFRA_DIR}/tests/disaster-recovery"

# Run DR tests directly via ginkgo from infra-deployments
timeout "$DR_TIMEOUT" ginkgo \
    -v \
    --no-color \
    --output-interceptor-mode=none \
    --timeout=180m \
    --fail-on-empty \
    --label-filter="${DR_LABEL}" \
    --junit-report=dr-tests-report.xml \
    --output-dir="${ARTIFACT_DIR}" \
    "${E2E_BIN_PATH}" \
    2>&1 | tee "${ARTIFACT_DIR}/dr-tests.log"
