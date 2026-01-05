#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Starting prow-failure-analysis..."

if [[ -z "${LLM_PROVIDER:-}" ]]; then
    echo "ERROR: LLM_PROVIDER is required but not set"
    exit 1
fi

if [[ -z "${LLM_MODEL:-}" ]]; then
    echo "ERROR: LLM_MODEL is required but not set"
    exit 1
fi

if [[ -z "${LLM_API_KEY_PATH:-}" ]]; then
    echo "ERROR: LLM_API_KEY_PATH is required but not set"
    exit 1
fi

if [[ ! -f "${LLM_API_KEY_PATH}" ]]; then
    echo "ERROR: LLM API key file not found at ${LLM_API_KEY_PATH}"
    echo "Make sure you have mounted your secret correctly in the CI config"
    exit 1
fi

# read the LLM API key from the mounted secret
export LLM_API_KEY
LLM_API_KEY=$(cat "${LLM_API_KEY_PATH}")

# set optional LLM base URL if provided
if [[ -n "${LLM_BASE_URL:-}" ]]; then
    export LLM_BASE_URL
fi

# read GitHub token if provided for PR comments
if [[ -n "${GITHUB_TOKEN_PATH:-}" ]] && [[ -f "${GITHUB_TOKEN_PATH}" ]]; then
    export GITHUB_TOKEN
    GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
fi

export JOB_NAME="${JOB_NAME:-}"
export BUILD_ID="${BUILD_ID:-}"
export PULL_NUMBER="${PULL_NUMBER:-}"

# construct ORG_REPO from Prow variables if not explicitly set
if [[ -z "${ORG_REPO:-}" ]] && [[ -n "${REPO_OWNER:-}" ]] && [[ -n "${REPO_NAME:-}" ]]; then
    export ORG_REPO="${REPO_OWNER}/${REPO_NAME}"
fi

# export optional configuration
export GCS_BUCKET="${GCS_BUCKET:-test-platform-results}"

if [[ -n "${GCS_CREDS_PATH:-}" ]]; then
    export GCS_CREDS_PATH
fi

if [[ -n "${IGNORED_STEPS:-}" ]]; then
    export IGNORED_STEPS
fi

if [[ -n "${INCLUDED_ARTIFACTS:-}" ]]; then
    export INCLUDED_ARTIFACTS
fi

export CORDON_DEVICE="${CORDON_DEVICE:-cpu}"
export CORDON_BACKEND="${CORDON_BACKEND:-sentence-transformers}"
export CORDON_MODEL_NAME="${CORDON_MODEL_NAME:-all-MiniLM-L6-v2}"
export CORDON_BATCH_SIZE="${CORDON_BATCH_SIZE:-32}"

# handle remote embedding API key if provided
if [[ -n "${CORDON_API_KEY_PATH:-}" ]] && [[ -f "${CORDON_API_KEY_PATH}" ]]; then
    export CORDON_API_KEY
    CORDON_API_KEY=$(cat "${CORDON_API_KEY_PATH}")
fi

if [[ -n "${CORDON_ENDPOINT:-}" ]]; then
    export CORDON_ENDPOINT
fi

# build the command
cmd="prow-failure-analysis analyze"

if [[ -n "${PULL_NUMBER:-}" ]]; then
    cmd+=" --pr-number ${PULL_NUMBER}"
fi

if [[ -n "${ORG_REPO:-}" ]]; then
    cmd+=" --org-repo ${ORG_REPO}"
fi

if [[ "${POST_COMMENT:-false}" == "true" ]] && [[ -n "${GITHUB_TOKEN:-}" ]]; then
    cmd+=" --post-comment"
fi

if [[ "${VERBOSE:-false}" == "true" ]]; then
    cmd+=" --verbose"
fi

echo "Executing: ${cmd}"
echo "LLM Provider: ${LLM_PROVIDER}"
echo "LLM Model: ${LLM_MODEL}"
echo "GCS Bucket: ${GCS_BUCKET}"
echo "Embedding Backend: ${CORDON_BACKEND}"
echo "Embedding Model: ${CORDON_MODEL_NAME}"
echo "Embedding Device: ${CORDON_DEVICE}"

# execute the analysis
set +e
eval "${cmd}"
exit_code=$?
set -e

if [[ ${exit_code} -eq 0 ]]; then
    echo "prow-failure-analysis completed successfully"
else
    echo "WARNING: prow-failure-analysis exited with code ${exit_code}"
    echo "This may indicate an API error or configuration issue."
    echo "The CI job result is not affected by this failure."
fi
