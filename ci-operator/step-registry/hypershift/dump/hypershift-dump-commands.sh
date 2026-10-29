#!/bin/bash

set -exuo pipefail

if [[ -n "${HYPERSHIFT_CLUSTER_ROLE:-}" ]]; then
  if [[ ! "${HYPERSHIFT_CLUSTER_ROLE}" =~ ^[a-z0-9-]+$ ]]; then
    echo "HYPERSHIFT_CLUSTER_ROLE must contain only lowercase letters, digits, or hyphens" >&2
    exit 1
  fi
  export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig_${HYPERSHIFT_CLUSTER_ROLE}"
  if [[ ! -s "${KUBECONFIG}" ]]; then
    echo "Management cluster kubeconfig ${KUBECONFIG} is missing or empty" >&2
    exit 1
  fi
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  set +x
  source "${SHARED_DIR}/proxy-conf.sh"
  set -x
fi

# Dump resourced under the namespace for shared ingress if needed
if [[ -n "$HYPERSHIFT_MANAGED_SERVICE" ]]; then
  export MANAGED_SERVICE="$HYPERSHIFT_MANAGED_SERVICE"
fi

if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
  CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"
else
  CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
fi
bin/hypershift dump cluster --artifact-dir=$ARTIFACT_DIR \
--dump-guest-cluster=true \
--name="${CLUSTER_NAME}"
