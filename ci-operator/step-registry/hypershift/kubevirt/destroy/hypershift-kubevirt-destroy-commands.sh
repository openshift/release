#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

MCE=${MCE_VERSION:-""}
CLUSTER_NAME="$(echo -n "${PROW_JOB_ID}" | sha256sum | cut -c-20)"
if [[ -n ${MCE} ]]; then
  CLUSTER_NAMESPACE_PREFIX=local-cluster
else
  CLUSTER_NAMESPACE_PREFIX=clusters
fi

HCP_CLI="/usr/bin/hcp"
if [[ ! -f ${HCP_CLI} ]]; then
  HCP_CLI="/usr/bin/hypershift"
fi
echo "Using ${HCP_CLI} for cli"

if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
  CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"
fi

if [[ -n "${HYPERSHIFT_KUBEVIRT_CLUSTER_DESTROY_TIMEOUT:-}" ]]; then
  DESTROY_TIMEOUT_SECONDS="${HYPERSHIFT_KUBEVIRT_CLUSTER_DESTROY_TIMEOUT}"
elif [[ "${ATTACH_DEFAULT_NETWORK:-}" == "localnet-multi" ]]; then
  # localnet-multi teardown can take longer (VMs, NADs, OVN ports).
  DESTROY_TIMEOUT_SECONDS=3600
else
  DESTROY_TIMEOUT_SECONDS=1800
fi

CLUSTER_GRACE_PERIOD="$((DESTROY_TIMEOUT_SECONDS / 60))m"
STEP_DEADLINE=$(($(date +%s) + DESTROY_TIMEOUT_SECONDS))
echo "Cluster destroy timeout: ${DESTROY_TIMEOUT_SECONDS}s (grace period ${CLUSTER_GRACE_PERIOD}, ATTACH_DEFAULT_NETWORK=${ATTACH_DEFAULT_NETWORK:-})"

remaining_seconds() {
  local remaining=$((STEP_DEADLINE - $(date +%s)))
  if [[ ${remaining} -le 0 ]]; then
    echo 0
  else
    echo "${remaining}"
  fi
}

if ! oc get hostedcluster "${CLUSTER_NAME}" -n "${CLUSTER_NAMESPACE_PREFIX}" --request-timeout=10s &>/dev/null; then
  echo "WARNING: HostedCluster/${CLUSTER_NAME} not found in ${CLUSTER_NAMESPACE_PREFIX}. Skipping destroy."
  exit 0
fi

echo "$(date) Deleting HyperShift cluster ${CLUSTER_NAME}"
destroy_remaining="$(remaining_seconds)"
if [[ "${destroy_remaining}" -eq 0 ]]; then
  echo "Destroy timeout budget exhausted before starting destroy"
  exit 1
fi

timeout --signal=SIGTERM "${destroy_remaining}s" \
  "${HCP_CLI}" destroy cluster kubevirt \
    --name "${CLUSTER_NAME}" \
    --cluster-grace-period "${CLUSTER_GRACE_PERIOD}"

echo "$(date) Waiting for HostedCluster ${CLUSTER_NAME} to be deleted (budget ${DESTROY_TIMEOUT_SECONDS}s total)"
while oc get hostedcluster "${CLUSTER_NAME}" -n "${CLUSTER_NAMESPACE_PREFIX}" &>/dev/null; do
  wait_remaining="$(remaining_seconds)"
  if [[ "${wait_remaining}" -eq 0 ]]; then
    echo "Timed out waiting for HostedCluster deletion after ${DESTROY_TIMEOUT_SECONDS}s"
    oc get hostedcluster "${CLUSTER_NAME}" -n "${CLUSTER_NAMESPACE_PREFIX}" -o yaml || true
    exit 1
  fi
  echo "$(date --rfc-3339=seconds) HostedCluster still present, retrying in 30s (${wait_remaining}s remaining in destroy budget)"
  sleep 30s
done

echo "$(date) Finished deleting cluster"
