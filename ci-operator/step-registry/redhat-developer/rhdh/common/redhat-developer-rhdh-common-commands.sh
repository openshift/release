#!/bin/bash
# Common utility functions for RHDH CI scripts
# This step provides reusable functions that can be sourced by other steps

# Set strict error handling
set -euo pipefail

# =============================================================================
# WORKDIR SETUP FUNCTIONS
# =============================================================================

# Setup basic working directory and environment
setup_workdir() {
    echo "========== Workdir Setup =========="
    export HOME WORKSPACE
    HOME=/tmp
    WORKSPACE=$(pwd)
    cd /tmp || exit
}

# =============================================================================
# SERVICE ACCOUNT AND TOKEN MANAGEMENT FUNCTIONS
# =============================================================================

# Create or retrieve service account token for Kubernetes cluster
# Usage: setup_service_account_token [namespace] [service_account_name]
setup_service_account_token() {
    local sa_namespace="${1:-default}"
    local sa_name="${2:-tester-sa-2}"
    local sa_binding_name="${sa_name}-binding"
    local sa_secret_name="${sa_name}-secret"

    echo "========== Cluster Service Account and Token Management =========="
    echo "Setting up service account: ${sa_name} in namespace: ${sa_namespace}"

    # Try to get existing token first
    if token="$(kubectl get secret ${sa_secret_name} -n ${sa_namespace} -o jsonpath='{.data.token}' 2>/dev/null)"; then
        K8S_CLUSTER_TOKEN=$(echo "${token}" | base64 --decode)
        echo "Acquired existing token for the service account into K8S_CLUSTER_TOKEN"
    else
        echo "Creating service account"
        if ! kubectl get serviceaccount ${sa_name} -n ${sa_namespace} &> /dev/null; then
            echo "Creating service account ${sa_name}..."
            kubectl create serviceaccount ${sa_name} -n ${sa_namespace}
            echo "Creating cluster role binding..."
            kubectl create clusterrolebinding ${sa_binding_name} \
                --clusterrole=cluster-admin \
                --serviceaccount=${sa_namespace}:${sa_name}
            echo "Service account and binding created successfully"
        else
            echo "Service account ${sa_name} already exists in namespace ${sa_namespace}"
        fi
        
        echo "Creating secret for service account"
        kubectl apply --namespace="${sa_namespace}" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${sa_secret_name}
  namespace: ${sa_namespace}
  annotations:
    kubernetes.io/service-account.name: ${sa_name}
type: kubernetes.io/service-account-token
EOF

        # Wait for token to be available with retries
        local retries=12
        local sleep_time=5
        for ((i=1; i <= retries; i++)); do
            if token="$(kubectl get secret ${sa_secret_name} -n ${sa_namespace} -o jsonpath='{.data.token}' 2>/dev/null)"; then
                echo "Successfully got token on attempt $i."
                break
            elif [ $i -eq $retries ]; then
                echo "Failed to get token after $i attempts. Exiting..."
                exit 1
            else
                echo "Failed to get token on attempt $i, retrying..."
            fi
            sleep $sleep_time
        done
        K8S_CLUSTER_TOKEN=$(echo "${token}" | base64 --decode)
        echo "Acquired token for the service account into K8S_CLUSTER_TOKEN"
    fi
    
    # Get cluster URL
    K8S_CLUSTER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    export K8S_CLUSTER_TOKEN K8S_CLUSTER_URL
}

# =============================================================================
# GIT REPOSITORY FUNCTIONS
# =============================================================================

# Setup Git repository and checkout appropriate branch
# Usage: setup_git_repository [github_org] [github_repo]
setup_git_repository() {
    local github_org="${1:-redhat-developer}"
    local github_repo="${2:-rhdh}"
    
    echo "========== Git Repository Setup & Checkout =========="
    
    # Prepare git variables
    export GIT_PR_NUMBER GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME TAG_NAME
    GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
    echo "GIT_PR_NUMBER : $GIT_PR_NUMBER"
    GITHUB_ORG_NAME="${github_org}"
    GITHUB_REPOSITORY_NAME="${github_repo}"

    export QUAY_REPO RELEASE_BRANCH_NAME
    QUAY_REPO="rhdh-community/rhdh"
    # Get the base branch name based on job.
    RELEASE_BRANCH_NAME=$(echo ${JOB_SPEC} | jq -r '.extra_refs[].base_ref' 2>/dev/null || echo ${JOB_SPEC} | jq -r '.refs.base_ref')

    # Clone and checkout the specific PR
    git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
    cd "${GITHUB_REPOSITORY_NAME}" || exit
    git checkout "$RELEASE_BRANCH_NAME" || exit

    git config --global user.name "rhdh-qe"
    git config --global user.email "rhdh-qe@redhat.com"
}

# Handle PR branch checkout and merge
# Usage: handle_pr_branch
handle_pr_branch() {
    echo "========== PR Branch Handling =========="
    if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
        # If executed as PR check of the repository, switch to PR branch.
        git fetch origin pull/"${GIT_PR_NUMBER}"/head:PR"${GIT_PR_NUMBER}"
        git checkout PR"${GIT_PR_NUMBER}"
        git merge origin/$RELEASE_BRANCH_NAME --no-edit
        GIT_PR_RESPONSE=$(curl -s "https://api.github.com/repos/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}/pulls/${GIT_PR_NUMBER}")
        LONG_SHA=$(echo "$GIT_PR_RESPONSE" | jq -r '.head.sha')
        SHORT_SHA=$(git rev-parse --short=8 ${LONG_SHA})
        TAG_NAME="pr-${GIT_PR_NUMBER}-${SHORT_SHA}"
        echo "TAG_NAME: $TAG_NAME"
        IMAGE_NAME="${QUAY_REPO}:${TAG_NAME}"
        echo "IMAGE_NAME: $IMAGE_NAME"
    fi
}

# Analyze changeset to determine if changes are only in specific directories
# Usage: analyze_changeset [directories_pattern]
analyze_changeset() {
    local directories_pattern="${1:-.ibm|e2e-tests|docs|.cursor}"
    
    echo "========== Changeset Analysis =========="
    PR_CHANGESET=$(git diff --name-only $RELEASE_BRANCH_NAME)
    echo "Changeset: $PR_CHANGESET"

    # Check if changes are exclusively within the specified directories
    ONLY_IN_DIRS=true

    for change in $PR_CHANGESET; do
        # Check if the change is not within the specified directories
        if ! echo "$change" | grep -qE "^($directories_pattern)/"; then
            ONLY_IN_DIRS=false
            break
        fi
    done

    echo "ONLY_IN_DIRS: $ONLY_IN_DIRS"
    export ONLY_IN_DIRS
}

# =============================================================================
# IMAGE MANAGEMENT FUNCTIONS
# =============================================================================

# Wait for Docker image to be available on Quay.io
# Usage: wait_for_image [quay_repo] [tag_name] [max_wait_minutes] [poll_interval_seconds]
wait_for_image() {
    local quay_repo="${1}"
    local tag_name="${2}"
    local max_wait_minutes="${3:-60}"
    local poll_interval_seconds="${4:-60}"
    
    local max_wait_time_seconds=$((max_wait_minutes * 60))
    local elapsed_time=0

    echo "Waiting for Docker image ${quay_repo}:${tag_name} to be available..."

    while true; do
        # Check image availability
        response=$(curl -s "https://quay.io/api/v1/repository/${quay_repo}/tag/?specificTag=$tag_name")

        # Use jq to parse the JSON and see if the tag exists
        tag_count=$(echo $response | jq '.tags | length')

        if [ "$tag_count" -gt "0" ]; then
            echo "Docker image ${quay_repo}:${tag_name} is now available. Time elapsed: $(($elapsed_time / 60)) minute(s)."
            break
        fi

        # Wait for the interval duration
        sleep $poll_interval_seconds

        # Increment the elapsed time
        elapsed_time=$(($elapsed_time + $poll_interval_seconds))

        # If the elapsed time exceeds the timeout, exit with an error
        if [ $elapsed_time -ge $max_wait_time_seconds ]; then
            echo "Timed out waiting for Docker image ${quay_repo}:${tag_name}. Time elapsed: $(($elapsed_time / 60)) minute(s)."
            exit 1
        fi
    done
}

# Resolve image tag based on job type and branch
# Usage: resolve_image_tag [platform_type]
resolve_image_tag() {
    local platform_type="${1:-community}"
    # Note: platform_type parameter is reserved for future use
    
    echo "========== Image Tag Resolution =========="
    
    if [[ "$JOB_NAME" == rehearse-* || "$JOB_TYPE" == "periodic" ]]; then
        QUAY_REPO="rhdh/rhdh-hub-rhel9"
        if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
            # Get branch a specific tag name (e.g., 'release-1.5' becomes '1.5')
            TAG_NAME="$(echo $RELEASE_BRANCH_NAME | cut -d'-' -f2)"
        else
            TAG_NAME="next"
        fi
        echo "TAG_NAME: $TAG_NAME"
    elif [[ "$ONLY_IN_DIRS" == "true" && "$JOB_TYPE" == "presubmit" ]]; then
        if [ "${RELEASE_BRANCH_NAME}" != "main" ]; then
            QUAY_REPO="rhdh/rhdh-hub-rhel9"
            # Get branch a specific tag name (e.g., 'release-1.5' becomes '1.5')
            TAG_NAME="$(echo $RELEASE_BRANCH_NAME | cut -d'-' -f2)"
        else
            QUAY_REPO="rhdh-community/rhdh"
            TAG_NAME="next"
        fi
        echo "INFO: Bypassing PR image build wait, using tag: ${TAG_NAME}"
        echo "INFO: Container image will be tagged as: ${QUAY_REPO}:${TAG_NAME}"
    else
        # Wait for PR image to be built
        wait_for_image "${QUAY_REPO}" "${TAG_NAME}"
    fi
    
    echo "========== Current branch =========="
    echo "Current branch: $(git branch --show-current)"
    echo "Using Image: ${QUAY_REPO}:${TAG_NAME}"
}

# =============================================================================
# TEST EXECUTION FUNCTIONS
# =============================================================================

# Execute the main test script
# Usage: execute_tests
execute_tests() {
    echo "========== Test Execution =========="
    echo "Executing openshift-ci-tests.sh"
    bash ./.ibm/pipelines/openshift-ci-tests.sh
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Print section header
# Usage: print_section [section_name]
print_section() {
    local section_name="${1}"
    echo "========== ${section_name} =========="
}

# Check if required environment variables are set
# Usage: check_required_env [var1] [var2] ...
check_required_env() {
    local missing_vars=()
    
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "Error: Missing required environment variables: ${missing_vars[*]}"
        exit 1
    fi
}

# Log function entry for debugging
# Usage: log_function_entry [function_name] [args...]
log_function_entry() {
    local function_name="${1}"
    shift
    echo "[DEBUG] Entering function: ${function_name} with args: $*"
}
