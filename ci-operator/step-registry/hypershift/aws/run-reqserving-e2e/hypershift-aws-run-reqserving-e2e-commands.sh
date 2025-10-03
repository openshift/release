#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

function cleanup() {
  for child in $( jobs -p ); do
    kill "${child}"
  done
  wait
}
trap cleanup EXIT

# Set environment variables for run-reqserving-e2e.sh
export E2E_ARTIFACT_DIR="${ARTIFACT_DIR:-./artifacts}"
export E2E_LATEST_RELEASE_IMAGE="${OCP_IMAGE_LATEST}"
export E2E_PREVIOUS_RELEASE_IMAGE="${OCP_IMAGE_PREVIOUS:-}"
export E2E_HYPERSHIFT_OPERATOR_LATEST_IMAGE="${CI_HYPERSHIFT_OPERATOR:-}"
export E2E_EXTERNAL_DNS_DOMAIN="service.ci.hypershift.devcluster.openshift.com"
export E2E_PULL_SECRET_FILE="${CLUSTER_PROFILE_DIR}/pull-secret"

# AWS specific configuration
TARGET_AWS_REGION="$(cat ${SHARED_DIR}/aws-region)"
export E2E_AWS_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export E2E_AWS_PRIVATE_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export E2E_AWS_PRIVATE_REGION="${TARGET_AWS_REGION}"
export E2E_AWS_OIDC_S3_CREDENTIALS="/etc/hypershift-pool-aws-credentials/credentials"
export E2E_AWS_OIDC_S3_REGION="us-east-1"
export E2E_AWS_REGION="${TARGET_AWS_REGION}"

# Set AWS OIDC S3 bucket
export E2E_AWS_OIDC_S3_BUCKET_NAME="${AWS_OIDC_S3_BUCKET_NAME:-hypershift-ci-oidc}"

# External DNS configuration
export E2E_EXTERNAL_DNS_PROVIDER="aws"
export E2E_EXTERNAL_DNS_DOMAIN_FILTER="service.ci.hypershift.devcluster.openshift.com"
export E2E_EXTERNAL_DNS_CREDENTIALS="/etc/hypershift-pool-aws-credentials/credentials"

# Platform monitoring
export E2E_PLATFORM_MONITORING="All"

# Test execution options
export E2E_DRY_RUN="false"
export E2E_TEST_TIMEOUT="4h"
export E2E_VERBOSE="true"

# Invoke the run-reqserving-e2e.sh script
exec hack/run-reqserving-e2e.sh
