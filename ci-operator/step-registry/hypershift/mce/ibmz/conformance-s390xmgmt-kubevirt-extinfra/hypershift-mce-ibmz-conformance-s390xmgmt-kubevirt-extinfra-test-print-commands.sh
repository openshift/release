#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MGMT_KUBECONFIG="${SHARED_DIR}/kubeconfig"
INFRA_KUBECONFIG="${SHARED_DIR}/infra/kubeconfig"

echo "============================================================"
echo "Management cluster nodes (KUBECONFIG=${MGMT_KUBECONFIG})"
echo "============================================================"
KUBECONFIG="${MGMT_KUBECONFIG}" oc get nodes -o wide

echo ""
echo "============================================================"
echo "Infra cluster nodes (KUBECONFIG=${INFRA_KUBECONFIG})"
echo "============================================================"
KUBECONFIG="${INFRA_KUBECONFIG}" oc get nodes -o wide
