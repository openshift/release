#!/bin/bash

set -exuo pipefail

# Target: management cluster - destroying Cluster B (external infra KubeVirt HCP)
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: Management cluster kubeconfig not found at ${SHARED_DIR}/kubeconfig"
  exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Download hcp CLI from MCE's ConsoleCLIDownload
HYPERSHIFT_NAME=hcp
arch=$(arch)
if [ "$arch" == "x86_64" ]; then
  downURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href') && curl -k --output /tmp/${HYPERSHIFT_NAME}.tar.gz ${downURL}
  cd /tmp && tar -xvf /tmp/${HYPERSHIFT_NAME}.tar.gz
  chmod +x /tmp/${HYPERSHIFT_NAME}
  cd -
fi
HCP_CLI="/tmp/${HYPERSHIFT_NAME}"

CLUSTER_NAME="$(echo -n "${PROW_JOB_ID}-ext"|sha256sum|cut -c-20)"
echo "$(date) Deleting external infra HyperShift cluster ${CLUSTER_NAME}"
$HCP_CLI destroy cluster kubevirt \
  --name "${CLUSTER_NAME}" \
  --namespace local-cluster \
  --cluster-grace-period 15m || true

echo "$(date) Finished deleting external infra cluster"
