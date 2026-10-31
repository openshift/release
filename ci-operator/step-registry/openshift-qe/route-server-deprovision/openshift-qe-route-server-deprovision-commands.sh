#!/bin/bash
set -euo pipefail

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

# --- read Route Server ID ---------------------------------------------------

ROUTE_SERVER_ID_FILE="${SHARED_DIR}/route-server-id"
if [[ ! -s "${ROUTE_SERVER_ID_FILE}" ]]; then
  echo "No route-server-id file found in SHARED_DIR; nothing to deprovision."
  exit 0
fi

ROUTE_SERVER_ID=$(<"${ROUTE_SERVER_ID_FILE}")
if [[ -z "${ROUTE_SERVER_ID}" ]]; then
  echo "Route Server ID file is empty; nothing to deprovision."
  exit 0
fi

echo "=== Route Server Deprovision ==="
echo "  Region:          ${REGION}"
echo "  Route Server ID: ${ROUTE_SERVER_ID}"

# --- check current state -----------------------------------------------------

STATE=$(aws ec2 describe-route-servers \
  --route-server-ids "${ROUTE_SERVER_ID}" \
  --query 'RouteServers[0].State' \
  --output text 2>/dev/null || echo "not-found")

echo "  Current state: ${STATE}"

if [[ "${STATE}" == "not-found" || "${STATE}" == "None" || "${STATE}" == "deleted" ]]; then
  echo "  Route Server already deleted or not found; nothing to do."
  exit 0
fi

# --- delete Route Server -----------------------------------------------------

echo ""
echo "=== Deleting Route Server ${ROUTE_SERVER_ID} ==="
if ! aws ec2 delete-route-server --route-server-id "${ROUTE_SERVER_ID}" 2>/dev/null; then
  echo "WARNING: delete-route-server call failed; the resource may already be gone." >&2
  exit 0
fi
echo "  Deletion initiated."

# --- wait for deletion -------------------------------------------------------

POLL_INTERVAL=10
POLL_TIMEOUT=300   # 5 minutes
elapsed=0

echo ""
echo "=== Waiting for Route Server to be fully deleted ==="
while (( elapsed < POLL_TIMEOUT )); do
  STATE=$(aws ec2 describe-route-servers \
    --route-server-ids "${ROUTE_SERVER_ID}" \
    --query 'RouteServers[0].State' \
    --output text 2>/dev/null || echo "not-found")

  echo "  State: ${STATE} (${elapsed}s / ${POLL_TIMEOUT}s)"
  if [[ "${STATE}" == "not-found" || "${STATE}" == "None" || "${STATE}" == "deleted" ]]; then
    echo "  Route Server has been deleted."
    break
  fi
  if [[ "${STATE}" == "deleting" ]]; then
    sleep "${POLL_INTERVAL}"
    elapsed=$(( elapsed + POLL_INTERVAL ))
    continue
  fi
  # Unexpected state — log and break to avoid blocking the post chain
  echo "WARNING: Unexpected state '${STATE}'; continuing without waiting." >&2
  break
done

if (( elapsed >= POLL_TIMEOUT )); then
  echo "WARNING: Route Server did not reach 'deleted' within ${POLL_TIMEOUT}s." >&2
  echo "  Proceeding anyway; the resource may be cleaned up asynchronously." >&2
fi

echo ""
echo "=== Route Server deprovision complete ==="
