#!/bin/bash
set -euo pipefail

# --- configuration -----------------------------------------------------------

ROUTE_SERVER_ASN=65000
ROUTE_SERVER_TAG="bcc-ci-route-server"
POLL_INTERVAL=10
POLL_TIMEOUT=300   # 5 minutes

# --- AWS credentials and region ---------------------------------------------

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ ! -f "${AWS_SHARED_CREDENTIALS_FILE}" ]]; then
  if [[ -f "${SHARED_DIR}/aws_credentials" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${SHARED_DIR}/aws_credentials"
  elif [[ -f "${CLUSTER_PROFILE_DIR}/aws_credentials" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/aws_credentials"
  else
    echo "ERROR: No AWS credentials found in CLUSTER_PROFILE_DIR or SHARED_DIR" >&2
    exit 1
  fi
fi

REGION="${LEASED_RESOURCE:-${REGION:-}}"
if [[ -z "${REGION}" ]]; then
  echo "ERROR: Neither LEASED_RESOURCE nor REGION is set; cannot determine AWS region" >&2
  exit 1
fi
export AWS_DEFAULT_REGION="${REGION}"

echo "=== Route Server Provisioning ==="
echo "  Region: ${REGION}"
echo "  ASN:    ${ROUTE_SERVER_ASN}"

# --- discover VPC ID ---------------------------------------------------------

VPC_ID=""
if [[ -s "${SHARED_DIR}/vpc_id" ]]; then
  VPC_ID=$(<"${SHARED_DIR}/vpc_id")
  echo "  VPC ID (from SHARED_DIR/vpc_id): ${VPC_ID}"
elif [[ -s "${SHARED_DIR}/vpc-id" ]]; then
  VPC_ID=$(<"${SHARED_DIR}/vpc-id")
  echo "  VPC ID (from SHARED_DIR/vpc-id): ${VPC_ID}"
fi

if [[ -z "${VPC_ID}" ]]; then
  echo "  VPC ID not found in SHARED_DIR, attempting discovery via cluster nodes ..."
  PROVIDER_ID=$(oc get nodes -l node-role.kubernetes.io/worker \
    -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || echo "")
  INSTANCE_ID="${PROVIDER_ID##*/}"
  if [[ -n "${INSTANCE_ID}" ]]; then
    VPC_ID=$(aws ec2 describe-instances \
      --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].VpcId' \
      --output text 2>/dev/null || echo "")
  fi
fi

if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
  echo "ERROR: Could not determine VPC ID" >&2
  exit 1
fi
echo "  VPC ID: ${VPC_ID}"

# --- cleanup trap ------------------------------------------------------------

ROUTE_SERVER_ID=""
cleanup() {
  echo ""
  echo "=== Cleanup: deleting Route Server ==="
  if [[ -n "${ROUTE_SERVER_ID}" ]]; then
    if aws ec2 delete-route-server \
         --route-server-id "${ROUTE_SERVER_ID}" 2>/dev/null; then
      echo "  Route Server ${ROUTE_SERVER_ID} deletion initiated"
    else
      echo "  WARNING: Failed to delete Route Server ${ROUTE_SERVER_ID}" >&2
    fi
  else
    echo "  No Route Server to clean up"
  fi
}
trap cleanup EXIT

# --- create Route Server -----------------------------------------------------

echo ""
echo "=== Creating Route Server (ASN ${ROUTE_SERVER_ASN}) ==="
CREATE_OUTPUT=$(aws ec2 create-route-server \
  --amazon-side-asn "${ROUTE_SERVER_ASN}" \
  --tag-specifications "ResourceType=route-server,Tags=[{Key=Name,Value=${ROUTE_SERVER_TAG}},{Key=ci,Value=true}]" \
  --output json 2>&1) || {
    echo "ERROR: Failed to create Route Server" >&2
    echo "${CREATE_OUTPUT}" >&2
    if echo "${CREATE_OUTPUT}" | grep -q "AccessDenied\|UnauthorizedOperation"; then
      echo "" >&2
      echo "The AWS credentials do not have permission to create Route Servers." >&2
      echo "Required IAM permissions: ec2:CreateRouteServer, ec2:DeleteRouteServer," >&2
      echo "ec2:DescribeRouteServers, ec2:CreateTags" >&2
    fi
    # Clear so the trap does not try to delete a non-existent resource
    ROUTE_SERVER_ID=""
    exit 1
  }

ROUTE_SERVER_ID=$(echo "${CREATE_OUTPUT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['RouteServer']['RouteServerId'])" 2>/dev/null || echo "")

if [[ -z "${ROUTE_SERVER_ID}" ]]; then
  echo "ERROR: Could not parse Route Server ID from create response" >&2
  echo "${CREATE_OUTPUT}" >&2
  exit 1
fi
echo "  Route Server ID: ${ROUTE_SERVER_ID}"

# --- wait for "available" state ----------------------------------------------

echo ""
echo "=== Waiting for Route Server to reach 'available' state ==="
elapsed=0
while (( elapsed < POLL_TIMEOUT )); do
  STATE=$(aws ec2 describe-route-servers \
    --route-server-ids "${ROUTE_SERVER_ID}" \
    --query 'RouteServers[0].State' \
    --output text 2>/dev/null || echo "unknown")

  echo "  State: ${STATE} (${elapsed}s / ${POLL_TIMEOUT}s)"
  if [[ "${STATE}" == "available" ]]; then
    echo "  Route Server is available"
    break
  fi
  if [[ "${STATE}" == "failed" || "${STATE}" == "deleted" ]]; then
    echo "ERROR: Route Server entered '${STATE}' state" >&2
    exit 1
  fi

  sleep "${POLL_INTERVAL}"
  elapsed=$(( elapsed + POLL_INTERVAL ))
done

if [[ "${STATE}" != "available" ]]; then
  echo "ERROR: Route Server did not reach 'available' within ${POLL_TIMEOUT}s (last state: ${STATE})" >&2
  exit 1
fi

# --- persist Route Server ID for downstream steps ----------------------------

echo "${ROUTE_SERVER_ID}" > "${SHARED_DIR}/route-server-id"
echo ""
echo "=== Route Server ID written to SHARED_DIR/route-server-id ==="
echo "  ${ROUTE_SERVER_ID}"

# Disable the cleanup trap — the Route Server is now owned by the test job.
# The workflow's post chain (cluster deprovision) will clean up the VPC and
# its associated resources including the Route Server.
trap - EXIT
echo ""
echo "=== Route Server provisioning complete ==="
