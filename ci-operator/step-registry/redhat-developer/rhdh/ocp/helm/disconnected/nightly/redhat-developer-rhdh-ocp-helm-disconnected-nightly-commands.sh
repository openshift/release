#!/bin/bash
set -euo pipefail

echo "========== Disconnected Proxy Configuration =========="
# Source proxy configuration for network access in the disconnected environment.
# The disconnected workflow provisions a bastion host with a squid proxy;
# cluster nodes have NO direct internet access. The CI test pod can reach
# the internet only through this proxy.
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # Disable tracing due to proxy credential handling
    source "${SHARED_DIR}/proxy-conf.sh"
    echo "Proxy configuration loaded from ${SHARED_DIR}/proxy-conf.sh"
else
    echo "WARNING: proxy-conf.sh not found in SHARED_DIR — network calls may fail"
fi

export DISCONNECTED="true"
echo "DISCONNECTED=${DISCONNECTED}"

echo "========== Mirror Registry Variables =========="
# Read mirror registry connection details written by pre-phase steps.
# These are needed by prepare-restricted-environment.sh to mirror RHDH
# operator/operand images to the bastion mirror registry.
export MIRROR_REGISTRY_URL
MIRROR_REGISTRY_URL=$(head -n 1 "${SHARED_DIR}/mirror_registry_url" 2>/dev/null || true)
echo "MIRROR_REGISTRY_URL=${MIRROR_REGISTRY_URL}"

export BASTION_PUBLIC_ADDRESS
BASTION_PUBLIC_ADDRESS=$(cat "${SHARED_DIR}/bastion_public_address" 2>/dev/null || true)
echo "BASTION_PUBLIC_ADDRESS=${BASTION_PUBLIC_ADDRESS}"

export BASTION_SSH_USER
BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user" 2>/dev/null || true)
echo "BASTION_SSH_USER=${BASTION_SSH_USER}"

# Construct authenticated pull secret with mirror registry credentials.
# The vault secret at /var/run/vault/mirror-registry/ contains:
#   registry_creds     - plaintext user:password for the mirror registry
#   client_ca.crt      - CA certificate for TLS verification
#   registry_quay.json - quay.io credentials (for pulling source images)
#   registry_redhat.json - registry.redhat.io credentials
MIRROR_REGISTRY_CREDS_FILE="/var/run/vault/mirror-registry/registry_creds"
MIRROR_REGISTRY_CA_FILE="/var/run/vault/mirror-registry/client_ca.crt"

if [[ -z "${MIRROR_REGISTRY_URL}" ]]; then
    echo "ERROR: MIRROR_REGISTRY_URL is empty (${SHARED_DIR}/mirror_registry_url missing or empty)"
    exit 1
fi
if [[ ! -f "${MIRROR_REGISTRY_CREDS_FILE}" ]]; then
    echo "ERROR: Mirror registry credentials not found at ${MIRROR_REGISTRY_CREDS_FILE}"
    exit 1
fi
if [[ ! -f "${MIRROR_REGISTRY_CA_FILE}" ]]; then
    echo "ERROR: Mirror registry CA certificate not found at ${MIRROR_REGISTRY_CA_FILE}"
    exit 1
fi

export MIRROR_REGISTRY_CA="${MIRROR_REGISTRY_CA_FILE}"
echo "Mirror registry CA certificate: ${MIRROR_REGISTRY_CA}"

export MIRROR_REGISTRY_PULL_SECRET="${SHARED_DIR}/mirror_registry_pull_secret.json"
registry_cred=$(head -n 1 "${MIRROR_REGISTRY_CREDS_FILE}" | base64 -w 0)
jq --argjson a "{\"${MIRROR_REGISTRY_URL}\": {\"auth\": \"$registry_cred\"}}" \
    '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${MIRROR_REGISTRY_PULL_SECRET}"
echo "Mirror registry pull secret created at ${MIRROR_REGISTRY_PULL_SECRET}"

# Verify authenticated access to the mirror registry
registry_user_pass=$(head -n 1 "${MIRROR_REGISTRY_CREDS_FILE}")
if curl -sf --max-time 10 -o /dev/null --cacert "${MIRROR_REGISTRY_CA}" -u "${registry_user_pass}" "https://${MIRROR_REGISTRY_URL}/v2/"; then
    echo "PASS: Mirror registry at ${MIRROR_REGISTRY_URL} is accessible with credentials"
else
    echo "FAIL: Mirror registry at ${MIRROR_REGISTRY_URL} is not accessible with credentials"
    exit 1
fi

echo "========== Repository, Branch, and PR Variables =========="
GITHUB_ORG_NAME="redhat-developer"
echo "GITHUB_ORG_NAME: $GITHUB_ORG_NAME"
GITHUB_REPOSITORY_NAME="rhdh"
echo "GITHUB_REPOSITORY_NAME: $GITHUB_REPOSITORY_NAME"
RELEASE_BRANCH_NAME=$(echo "${JOB_SPEC}" | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo "${JOB_SPEC}" | jq -r '.refs.base_ref')
echo "RELEASE_BRANCH_NAME: $RELEASE_BRANCH_NAME"
GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
echo "GIT_PR_NUMBER: $GIT_PR_NUMBER"
TAG_NAME=""
IMAGE_REPO=""
IMAGE_REGISTRY="quay.io"
QUAY_REPO=""
CATALOG_INDEX_REGISTRY=""
CATALOG_INDEX_REPO=""
CATALOG_INDEX_TAG=""
CHART_VERSION=""
export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME RELEASE_BRANCH_NAME GIT_PR_NUMBER TAG_NAME IMAGE_REPO IMAGE_REGISTRY QUAY_REPO CATALOG_INDEX_REGISTRY CATALOG_INDEX_REPO CATALOG_INDEX_TAG CHART_VERSION

echo "========== Gangway API Overrides =========="
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_GITHUB_ORG_NAME}" ]]; then
    GITHUB_ORG_NAME="${MULTISTAGE_PARAM_OVERRIDE_GITHUB_ORG_NAME}"
    echo "Override applied: GITHUB_ORG_NAME=${GITHUB_ORG_NAME}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_GITHUB_REPOSITORY_NAME}" ]]; then
    GITHUB_REPOSITORY_NAME="${MULTISTAGE_PARAM_OVERRIDE_GITHUB_REPOSITORY_NAME}"
    echo "Override applied: GITHUB_REPOSITORY_NAME=${GITHUB_REPOSITORY_NAME}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_RELEASE_BRANCH_NAME}" ]]; then
    RELEASE_BRANCH_NAME="${MULTISTAGE_PARAM_OVERRIDE_RELEASE_BRANCH_NAME}"
    echo "Override applied: RELEASE_BRANCH_NAME=${RELEASE_BRANCH_NAME}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_GIT_PR_NUMBER}" ]]; then
    GIT_PR_NUMBER="${MULTISTAGE_PARAM_OVERRIDE_GIT_PR_NUMBER}"
    echo "Override applied: GIT_PR_NUMBER=${GIT_PR_NUMBER}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_TAG_NAME}" ]]; then
    TAG_NAME="${MULTISTAGE_PARAM_OVERRIDE_TAG_NAME}"
    echo "Override applied: TAG_NAME=${TAG_NAME}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_IMAGE_REPO}" ]]; then
    IMAGE_REPO="${MULTISTAGE_PARAM_OVERRIDE_IMAGE_REPO}"
    echo "Override applied: IMAGE_REPO=${IMAGE_REPO}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_IMAGE_REGISTRY}" ]]; then
    IMAGE_REGISTRY="${MULTISTAGE_PARAM_OVERRIDE_IMAGE_REGISTRY}"
    echo "Override applied: IMAGE_REGISTRY=${IMAGE_REGISTRY}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_CATALOG_INDEX_REGISTRY}" ]]; then
    CATALOG_INDEX_REGISTRY="${MULTISTAGE_PARAM_OVERRIDE_CATALOG_INDEX_REGISTRY}"
    echo "Override applied: CATALOG_INDEX_REGISTRY=${CATALOG_INDEX_REGISTRY}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_CATALOG_INDEX_REPO}" ]]; then
    CATALOG_INDEX_REPO="${MULTISTAGE_PARAM_OVERRIDE_CATALOG_INDEX_REPO}"
    echo "Override applied: CATALOG_INDEX_REPO=${CATALOG_INDEX_REPO}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_CATALOG_INDEX_TAG}" ]]; then
    CATALOG_INDEX_TAG="${MULTISTAGE_PARAM_OVERRIDE_CATALOG_INDEX_TAG}"
    echo "Override applied: CATALOG_INDEX_TAG=${CATALOG_INDEX_TAG}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_CHART_VERSION}" ]]; then
    CHART_VERSION="${MULTISTAGE_PARAM_OVERRIDE_CHART_VERSION}"
    echo "Override applied: CHART_VERSION=${CHART_VERSION}"
fi

echo "========== Workdir Setup =========="
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

echo "========== Cluster Authentication =========="
export OPENSHIFT_PASSWORD
export OPENSHIFT_API
export OPENSHIFT_USERNAME

OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' "$KUBECONFIG")"
OPENSHIFT_USERNAME="kubeadmin"

yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' "$KUBECONFIG"
if [[ -s "$KUBEADMIN_PASSWORD_FILE" ]]; then
    OPENSHIFT_PASSWORD="$(cat "$KUBEADMIN_PASSWORD_FILE")"
elif [[ -s "${SHARED_DIR}/kubeadmin-password" ]]; then
    # Recommendation from hypershift qe team in slack channel..
    OPENSHIFT_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"
else
    echo "Kubeadmin password file is empty... Aborting job"
    exit 1
fi

if ! timeout --foreground 10m bash <<-"EOF"; then
    while ! oc login "$OPENSHIFT_API" -u "$OPENSHIFT_USERNAME" -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            echo "Login failed, retrying in 30s..."
            sleep 30
    done
EOF
    echo "Timed out waiting for login"
    exit 1
fi

echo "========== Cluster Health Check =========="
echo "Waiting for all nodes to be ready..."
if ! oc wait --for=condition=Ready nodes --all --timeout=300s; then
    echo "Timed out waiting for nodes to become ready"
    exit 1
fi
echo "All nodes are ready"

echo "========== Disconnected Environment Verification =========="
VERIFICATION_FAILED=false

# 1. Verify cluster API is reachable through proxy
echo "--- Check 1: Cluster API reachability via proxy ---"
if oc get --raw /healthz 2>/dev/null; then
    echo "PASS: Cluster API is reachable (healthz returned ok)"
else
    echo "FAIL: Cluster API is not reachable through proxy"
    VERIFICATION_FAILED=true
fi

# 2. Verify cluster nodes cannot reach the internet (network isolation)
echo "--- Check 2: Cluster node internet isolation ---"
NODE_NAME=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "${NODE_NAME}" ]]; then
    # Fall back to any node if no workers found
    NODE_NAME=$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

if [[ -n "${NODE_NAME}" ]]; then
    echo "Testing internet access from node: ${NODE_NAME}"
    # The curl inside the debug pod runs on the node's network stack (no proxy).
    # On a properly disconnected cluster, this MUST fail.
    if oc debug "node/${NODE_NAME}" --quiet -- chroot /host \
        curl -sf --max-time 10 -o /dev/null https://www.google.com 2>/dev/null; then
        echo "FAIL: Node ${NODE_NAME} can reach the internet — cluster is NOT disconnected"
        VERIFICATION_FAILED=true
    else
        echo "PASS: Node ${NODE_NAME} cannot reach the internet — cluster is properly disconnected"
    fi
else
    echo "WARNING: Could not determine node name, skipping internet isolation check"
fi

# 3. Verify default catalog sources are disabled
echo "--- Check 3: Default catalog sources disabled ---"
DISABLE_STATUS=$(oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}' 2>/dev/null)
if [[ "${DISABLE_STATUS}" == "true" ]]; then
    echo "PASS: Default catalog sources are disabled (disableAllDefaultSources=true)"
else
    echo "FAIL: Default catalog sources are NOT disabled (disableAllDefaultSources=${DISABLE_STATUS:-unset})"
    VERIFICATION_FAILED=true
fi

# Summary
echo "--- Disconnected Environment Verification Summary ---"
if [[ "${VERIFICATION_FAILED}" == "true" ]]; then
    echo "ERROR: One or more disconnected environment checks failed. Review the output above."
    exit 1
else
    echo "All disconnected environment checks passed."
fi

echo "========== HTPasswd Identity Provider =========="
# HTPasswd setup is opt-in via [debug] in the PR title — auth pod restarts add significant job time
PR_TITLE=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].title // empty')
if [[ "$JOB_TYPE" != "periodic" ]] && [[ "$PR_TITLE" != *"[debug]"* ]]; then
    echo "Skipping HTPasswd identity provider setup. Add [debug] to PR title to enable."
elif [[ ! -f /tmp/secrets/EPHEMERAL_CLUSTER_ADMIN_USERNAME ]] || [[ ! -f /tmp/secrets/EPHEMERAL_CLUSTER_ADMIN_PASSWORD ]]; then
    echo "WARNING: EPHEMERAL_CLUSTER_ADMIN_* secrets not found, skipping HTPasswd identity provider setup"
else
    htpasswd -c -B -i users.htpasswd "$(cat /tmp/secrets/EPHEMERAL_CLUSTER_ADMIN_USERNAME)" <<< "$(cat /tmp/secrets/EPHEMERAL_CLUSTER_ADMIN_PASSWORD)"
    oc create secret generic htpass-secret --from-file=htpasswd=users.htpasswd -n openshift-config
    rm -f users.htpasswd
    oc patch oauth cluster --type=merge --patch='{"spec":{"identityProviders":[{"name":"cluster_admin","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"htpass-secret"}}}]}}'
    oc wait --for=condition=Progressing=False clusteroperator/authentication --timeout=10m
    oc wait --for=condition=Available=True clusteroperator/authentication --timeout=10m
    oc wait --for=condition=Ready pod --all -n openshift-authentication --timeout=400s
    oc adm policy add-cluster-role-to-user cluster-admin "$(cat /tmp/secrets/EPHEMERAL_CLUSTER_ADMIN_USERNAME)"
fi

echo "========== Cluster Service Account and Token Management =========="
export K8S_CLUSTER_URL K8S_CLUSTER_TOKEN
K8S_CLUSTER_URL=$(oc whoami --show-server)
echo "K8S_CLUSTER_URL: $K8S_CLUSTER_URL"

echo "Note: This is a disconnected cluster provisioned via IPI. It will be destroyed after the job completes."

oc create serviceaccount tester-sa-2 -n default
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:default:tester-sa-2
K8S_CLUSTER_TOKEN=$(oc create token tester-sa-2 -n default --duration=4h)

echo "========== Platform Environment Variables =========="
echo "Setting platform environment variables:"
export IS_OPENSHIFT="true"
echo "IS_OPENSHIFT=${IS_OPENSHIFT}"
export CONTAINER_PLATFORM="ocp"
echo "CONTAINER_PLATFORM=${CONTAINER_PLATFORM}"
echo "Getting container platform version"
CONTAINER_PLATFORM_VERSION=$(oc version --output json 2> /dev/null | jq -r '.openshiftVersion' | cut -d'.' -f1,2 || echo "unknown")
export CONTAINER_PLATFORM_VERSION
echo "CONTAINER_PLATFORM_VERSION=${CONTAINER_PLATFORM_VERSION}"

echo "========== Cluster kubeadmin logout =========="
oc logout

echo "========== Git Repository Setup & Checkout =========="
# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd "${GITHUB_REPOSITORY_NAME}" || exit
git checkout "$RELEASE_BRANCH_NAME" || exit

git config --global user.name "rhdh-qe"
git config --global user.email "rhdh-qe@redhat.com"

echo "========== PR Branch Handling =========="
if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]] && [[ -z "${MULTISTAGE_PARAM_OVERRIDE_TAG_NAME}" ]]; then
    # If executed as PR check of the repository, switch to PR branch.
    git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
    git checkout PR"${GIT_PR_NUMBER}"
    git merge origin/$RELEASE_BRANCH_NAME --no-edit
    GIT_PR_RESPONSE=$(curl -s "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/pulls/${GIT_PR_NUMBER}")
    LONG_SHA=$(echo "$GIT_PR_RESPONSE" | jq -r '.head.sha')
    SHORT_SHA=$(git rev-parse --short=8 ${LONG_SHA})
    TAG_NAME="pr-${GIT_PR_NUMBER}-${SHORT_SHA}"
    echo "TAG_NAME: $TAG_NAME"
    IMAGE_NAME="${IMAGE_REPO:-rhdh-community/rhdh}:${TAG_NAME}"
    echo "IMAGE_NAME: $IMAGE_NAME"
fi

echo "========== Changeset Analysis =========="
PR_CHANGESET=$(git diff --name-only $RELEASE_BRANCH_NAME)
echo "Changeset: $PR_CHANGESET"

# Check if changes are exclusively within the specified directories
DIRECTORIES_TO_CHECK=".ci|e2e-tests|docs|.claude|.cursor|.opencode|.rulesync|.vscode"
ONLY_IN_DIRS=true

for change in $PR_CHANGESET; do
    # Check if the change is not within the specified directories
    if ! echo "$change" | grep -qE "^($DIRECTORIES_TO_CHECK)/"; then
        ONLY_IN_DIRS=false
        break
    fi
done

echo "ONLY_IN_DIRS: $ONLY_IN_DIRS"

echo "========== Image Tag Resolution =========="
if [[ -n "${IMAGE_REPO}" && -n "${TAG_NAME}" ]]; then
    echo "Using overridden IMAGE_REPO: $IMAGE_REPO, TAG_NAME: $TAG_NAME"
elif [[ "$JOB_NAME" == rehearse-* || "$JOB_TYPE" == "periodic" ]]; then
    IMAGE_REPO="rhdh/rhdh-hub-rhel9"
    if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
        # Get branch a specific tag name (e.g., 'release-1.5' becomes '1.5')
        TAG_NAME="$(echo $RELEASE_BRANCH_NAME | cut -d'-' -f2)"
    else
        TAG_NAME="next"
    fi
    echo "TAG_NAME: $TAG_NAME"
elif [[ "$ONLY_IN_DIRS" == "true" && "$JOB_TYPE" == "presubmit" ]];then
    IMAGE_REPO="rhdh-community/rhdh"
    if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
        # Get branch version (e.g., 'release-1.5' becomes '1.5') and prefix with 'next-'
        VERSION="$(echo $RELEASE_BRANCH_NAME | cut -d'-' -f2)"
        TAG_NAME="next-${VERSION}"
    else
        TAG_NAME="next"
    fi
    echo "INFO: Bypassing PR image build wait, using tag: ${TAG_NAME}"
    echo "INFO: Container image will be tagged as: ${IMAGE_REPO}:${TAG_NAME}"
else
    IMAGE_REPO="rhdh-community/rhdh"
    IMAGE_NAME="${IMAGE_REPO}:${TAG_NAME}"
    if [[ "${IMAGE_REGISTRY}" == "quay.io" ]]; then
        echo "Waiting for Docker image availability..."
        # Timeout configuration for waiting for Docker image availability
        MAX_WAIT_TIME_SECONDS=$((60*60))    # Maximum wait time in minutes * seconds
        POLL_INTERVAL_SECONDS=60      # Check every 60 seconds

        ELAPSED_TIME=0

        while true; do
            # Check image availability
            response=$(curl -s "https://quay.io/api/v1/repository/${IMAGE_REPO}/tag/?specificTag=$TAG_NAME")

            # Use jq to parse the JSON and see if the tag exists
            tag_count=$(echo $response | jq '.tags | length')

            if [ "$tag_count" -gt "0" ]; then
                echo "Docker image $IMAGE_NAME is now available. Time elapsed: $(($ELAPSED_TIME / 60)) minute(s)."
                break
            fi

            # Wait for the interval duration
            sleep $POLL_INTERVAL_SECONDS

            # Increment the elapsed time
            ELAPSED_TIME=$(($ELAPSED_TIME + $POLL_INTERVAL_SECONDS))

            # If the elapsed time exceeds the timeout, exit with an error
            if [ $ELAPSED_TIME -ge $MAX_WAIT_TIME_SECONDS ]; then
                echo "Timed out waiting for Docker image $IMAGE_NAME. Time elapsed: $(($ELAPSED_TIME / 60)) minute(s)."
                exit 1
            fi
        done
    else
        echo "INFO: Skipping image availability check for non-quay.io registry: ${IMAGE_REGISTRY}"
    fi
fi
QUAY_REPO="${IMAGE_REPO}" # Keep QUAY_REPO in sync for backward compatibility

echo "========== Current branch =========="
echo "Current branch: $(git branch --show-current)"
if [[ "${IMAGE_REGISTRY}" == "quay.io" ]]; then
    IMAGE_SHA=$(curl -s "https://quay.io/api/v1/repository/${IMAGE_REPO}/tag/?specificTag=${TAG_NAME}" | jq -r '.tags[0].manifest_digest')
    echo "Using image: ${IMAGE_REGISTRY}/${IMAGE_REPO}:${TAG_NAME}, with digest: ${IMAGE_SHA}"
else
    echo "Using image: ${IMAGE_REGISTRY}/${IMAGE_REPO}:${TAG_NAME}"
fi

echo "========== Test Execution =========="
echo "Executing openshift-ci-tests.sh"
bash ./.ci/pipelines/openshift-ci-tests.sh
