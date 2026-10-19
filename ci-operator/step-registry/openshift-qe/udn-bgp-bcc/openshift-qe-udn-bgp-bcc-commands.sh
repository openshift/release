#!/bin/bash
set -euo pipefail

ES_SERVER=${ES_SERVER:-""}
PIN_SERVER=${PIN_SERVER:-""}
ITERATIONS=${ITERATIONS:-10}
ROUTE_SERVER_ID=${ROUTE_SERVER_ID:-""}

# Get AWS region from the cluster infrastructure
REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}' 2>/dev/null || echo "")
if [[ -z "${REGION}" ]]; then
  echo "ERROR: Could not determine AWS region from cluster infrastructure"
  exit 1
fi
echo "AWS Region: ${REGION}"

# Get VPC ID from the cluster infrastructure
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "")
if [[ -z "${INFRA_ID}" ]]; then
  echo "ERROR: Could not determine infrastructure name from cluster"
  exit 1
fi

# Source AWS credentials from cluster profile
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ ! -f "${AWS_SHARED_CREDENTIALS_FILE}" ]]; then
  # Try alternate credential paths
  if [[ -f "${SHARED_DIR}/aws_credentials" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${SHARED_DIR}/aws_credentials"
  elif [[ -f "${CLUSTER_PROFILE_DIR}/aws_credentials" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/aws_credentials"
  fi
fi
export AWS_DEFAULT_REGION="${REGION}"

# Discover VPC ID - prefer SHARED_DIR from ROSA HCP provision chain
VPC_ID=""
if [[ -s "${SHARED_DIR}/vpc_id" ]]; then
  VPC_ID=$(<"${SHARED_DIR}/vpc_id")
fi
if [[ -z "${VPC_ID}" ]]; then
  # Fall back to the VPC of a worker instance
  PROVIDER_ID=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || echo "")
  INSTANCE_ID="${PROVIDER_ID##*/}"
  if [[ -n "${INSTANCE_ID}" ]]; then
    VPC_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].VpcId' --output text 2>/dev/null || echo "")
  fi
fi
if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
  echo "ERROR: Could not determine VPC ID from cluster infrastructure"
  exit 1
fi
echo "VPC ID: ${VPC_ID}"

# Route Server ID - must be provided or discovered
if [[ -z "${ROUTE_SERVER_ID}" ]]; then
  # Try to read from SHARED_DIR (may be set by a prior setup step)
  if [[ -f "${SHARED_DIR}/route-server-id" ]]; then
    ROUTE_SERVER_ID=$(cat "${SHARED_DIR}/route-server-id")
  fi
fi
if [[ -z "${ROUTE_SERVER_ID}" ]]; then
  echo "ERROR: ROUTE_SERVER_ID not set and not found in SHARED_DIR/route-server-id"
  echo "The AWS VPC Route Server must be provisioned before running this workload."
  exit 1
fi
echo "Route Server ID: ${ROUTE_SERVER_ID}"

# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

# Set up ES credentials from mounted secret
if [[ -f /secret/perfscale/server ]]; then
  ES_SERVER=$(cat /secret/perfscale/server)
fi
if [[ -f /secret/perfscale/index ]]; then
  ES_INDEX=$(cat /secret/perfscale/index)
fi

$WAS_TRACING && set -x

# Clone e2e-benchmarking
git clone --depth=1 https://github.com/cloud-bulldozer/e2e-benchmarking.git /tmp/e2e-benchmarking
cd /tmp/e2e-benchmarking/workloads/kube-burner-ocp-wrapper

# Export variables for the wrapper
export WORKLOAD="${WORKLOAD:-udn-bgp-bcc}"
export ITERATIONS
export AWS_REGION="${REGION}"
export ROUTE_SERVER_ID
export VPC_ID
export EXTRA_FLAGS="--aws-region=${REGION} --route-server-id=${ROUTE_SERVER_ID} --vpc-id=${VPC_ID}"
export ES_SERVER
export ES_INDEX

if [[ -n "${PIN_SERVER}" ]]; then
  export PIN_SERVER
  export PIN_INDEX
fi

echo "Running udn-bgp-bcc workload with ${ITERATIONS} iterations"
echo "Extra flags: ${EXTRA_FLAGS}"

# Run the workload
./run.sh
