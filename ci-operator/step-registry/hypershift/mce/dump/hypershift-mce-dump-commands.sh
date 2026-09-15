#!/bin/bash

set -xeuo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
  CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"
else
  CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
fi

DUMP_GUEST_CLUSTER=${DUMP_GUEST_CLUSTER:-"true"}
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -o jsonpath="{.items[?(@.metadata.name=='${CLUSTER_NAME}')].metadata.namespace}" 2>/dev/null || true)
if [[ -z "${HOSTED_CLUSTER_NS}" ]]; then
  read -r HOSTED_CLUSTER_NS CLUSTER_NAME < <(oc get hostedcluster -A -o jsonpath='{.items[0].metadata.namespace}{" "}{.items[0].metadata.name}' 2>/dev/null || true)
fi
if [[ -z "${HOSTED_CLUSTER_NS}" || -z "${CLUSTER_NAME}" ]]; then
  echo "No HostedCluster found; skipping cluster dump"
  exit 0
fi
EXTRA_ARGS=""
PLATFORM_TYPE=$(oc get hostedclusters -n "${HOSTED_CLUSTER_NS}" "${CLUSTER_NAME}" -o jsonpath="{.spec.platform.type}" 2>/dev/null || true)
if [[ "${PLATFORM_TYPE}" == "Agent" ]]; then
  EXTRA_ARGS="${EXTRA_ARGS} --agent-namespace local-cluster-${CLUSTER_NAME}"
fi

bin/hypershift dump cluster "${EXTRA_ARGS}" \
--artifact-dir="${ARTIFACT_DIR}" \
--namespace "${HOSTED_CLUSTER_NS}" \
--dump-guest-cluster="${DUMP_GUEST_CLUSTER}" \
--name="${CLUSTER_NAME}"

