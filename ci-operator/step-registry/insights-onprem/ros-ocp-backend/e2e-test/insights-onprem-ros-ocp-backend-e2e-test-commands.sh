#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "========== Dependency Installation =========="

# Install yq if not available
if ! command -v yq &> /dev/null; then
    echo "yq not found, installing..."
    curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /tmp/yq
    chmod +x /tmp/yq
    export PATH="/tmp:${PATH}"
    echo "yq installed successfully"
else
    echo "yq is already installed"
fi

# Install kubectl if not available
if ! command -v kubectl &> /dev/null; then
    echo "kubectl not found, installing..."
    curl -sL "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o /tmp/kubectl
    chmod +x /tmp/kubectl
    export PATH="/tmp:${PATH}"
    echo "kubectl installed successfully"
else
    echo "kubectl is already installed"
fi

# Install helm if not available
if ! command -v helm &> /dev/null; then
    echo "helm not found, installing..."
    curl -sL https://get.helm.sh/helm-v3.13.0-linux-amd64.tar.gz -o /tmp/helm.tar.gz
    tar -xzf /tmp/helm.tar.gz -C /tmp
    mv /tmp/linux-amd64/helm /tmp/helm
    chmod +x /tmp/helm
    export PATH="/tmp:${PATH}"
    echo "helm installed successfully"
else
    echo "helm is already installed"
fi

echo "========== Image Tag Resolution =========="

export IMAGE_TAG

# Get job type and PR information from JOB_SPEC
JOB_TYPE=$(echo "${JOB_SPEC}" | jq -r '.type // "presubmit"')
echo "JOB_TYPE: ${JOB_TYPE}"

if [ "${JOB_TYPE}" == "presubmit" ] && [[ "${JOB_NAME}" != rehearse-* ]]; then
    echo "Running as presubmit job - resolving PR-based image tag"
    
    # Extract PR number and SHA from JOB_SPEC
    GIT_PR_NUMBER=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].number')
    echo "GIT_PR_NUMBER: ${GIT_PR_NUMBER}"
    
    # Get the PR commit SHA
    LONG_SHA=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[0].sha')
    SHORT_SHA=$(echo "${LONG_SHA}" | cut -c1-8)
    echo "SHORT_SHA: ${SHORT_SHA}"
    
    # Construct image tag: pr-<number>-<short-sha>
    IMAGE_TAG="pr-${GIT_PR_NUMBER}-${SHORT_SHA}"
    echo "Constructed IMAGE_TAG: ${IMAGE_TAG}"
    
    # Full image reference
    IMAGE_NAME="${QUAY_REPO}:${IMAGE_TAG}"
    echo "IMAGE_NAME: ${IMAGE_NAME}"
    
    echo "========== Waiting for Docker Image Availability =========="
    # Extract repository path from full quay URL
    REPO_PATH=$(echo "${QUAY_REPO}" | sed 's|^quay.io/||')
    
    # Timeout configuration for waiting for Docker image availability
    MAX_WAIT_TIME_SECONDS=$((60*60))  # Maximum wait time: 60 minutes
    POLL_INTERVAL_SECONDS=60          # Check every 60 seconds
    ELAPSED_TIME=0
    
    echo "Waiting for image ${IMAGE_NAME} to be available..."
    
    while true; do
        # Check image availability on Quay.io
        response=$(curl -s "https://quay.io/api/v1/repository/${REPO_PATH}/tag/?specificTag=${IMAGE_TAG}")
        
        # Use jq to parse the JSON and see if the tag exists
        tag_count=$(echo "${response}" | jq '.tags | length')
        
        if [ "${tag_count}" -gt "0" ]; then
            echo "Docker image ${IMAGE_NAME} is now available. Time elapsed: $((ELAPSED_TIME / 60)) minute(s)."
            break
        fi
        
        echo "Image not yet available. Waiting ${POLL_INTERVAL_SECONDS}s... (elapsed: $((ELAPSED_TIME / 60))m)"
        
        # Wait for the interval duration
        sleep ${POLL_INTERVAL_SECONDS}
        
        # Increment the elapsed time
        ELAPSED_TIME=$((ELAPSED_TIME + POLL_INTERVAL_SECONDS))
        
        # If the elapsed time exceeds the timeout, exit with an error
        if [ ${ELAPSED_TIME} -ge ${MAX_WAIT_TIME_SECONDS} ]; then
            echo "Timed out waiting for Docker image ${IMAGE_NAME}. Time elapsed: $((ELAPSED_TIME / 60)) minute(s)."
            echo "Please verify that the image build job completed successfully."
            exit 1
        fi
    done
else
    echo "Not a presubmit job or is a rehearsal - using default image tag"
    IMAGE_TAG="${IMAGE_TAG_DEFAULT}"
    echo "IMAGE_TAG: ${IMAGE_TAG}"
fi

echo "========== Final Image Configuration =========="
echo "Using Image: ${QUAY_REPO}:${IMAGE_TAG}"

echo "========== Running E2E Tests =========="
export IMAGE_TAG
make oc-deploy-test

