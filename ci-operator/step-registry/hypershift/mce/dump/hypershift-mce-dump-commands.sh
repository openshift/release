#!/bin/bash

set -xeuo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.namespace}')
EXTRA_ARGS=""
PLATFORM_TYPE=$(oc get hostedclusters -n ${HOSTED_CLUSTER_NS} ${CLUSTER_NAME} -ojsonpath="{.spec.platform.type}")
if [[ "${PLATFORM_TYPE}" == "Agent" ]]; then
  EXTRA_ARGS="${EXTRA_ARGS} --agent-namespace local-cluster-${CLUSTER_NAME}"
fi

bin/hypershift dump cluster "${EXTRA_ARGS}" \
--artifact-dir="${ARTIFACT_DIR}" \
--namespace "${HOSTED_CLUSTER_NS}" \
--dump-guest-cluster=true \
--name="${CLUSTER_NAME}"

