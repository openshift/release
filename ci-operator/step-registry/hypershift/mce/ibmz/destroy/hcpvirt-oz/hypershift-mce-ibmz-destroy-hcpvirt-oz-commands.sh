#!/bin/bash

set -x
set -e

echo "$(date) Targeting management cluster kubeconfig"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# --- Resolve HC identity from MetalLB pool (same logic as create step) ---
POOL_RANGE=$(oc get ipaddresspool -n metallb-system -o jsonpath='{.items[0].spec.addresses[0]}' 2>/dev/null || true)
echo "$(date) MetalLB IPAddressPool range: ${POOL_RANGE}"

if [[ "${POOL_RANGE}" == 192.168.2.* ]]; then
  HC_NAME=hcpvirt-oz-ci
  HC_NS=hcpvirt-oz-ci-ns
elif [[ "${POOL_RANGE}" == 192.168.3.* ]]; then
  HC_NAME=hcpvirtnew-oz-ci
  HC_NS=hcpvirtnew-oz-ci-ns
else
  echo "$(date) WARNING: Unrecognised IPAddressPool range '${POOL_RANGE}' — proceeding with best-effort cleanup"
  HC_NAME=hcpvirt-oz-ci
  HC_NS=hcpvirt-oz-ci-ns
fi

echo "$(date) Destroying hosted cluster HC_NAME=${HC_NAME} HC_NS=${HC_NS}"

# --- Destroy the HCP KubeVirt hosted cluster ---
echo "$(date) Installing hcp CLI"
mkdir -p /tmp/hcp_cli
downloadURL=$(oc get ConsoleCLIDownload hcp-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
curl -k --output /tmp/hcp.tar.gz "${downloadURL}"
tar -xvf /tmp/hcp.tar.gz -C /tmp/hcp_cli
chmod +x /tmp/hcp_cli/hcp
export PATH=$PATH:/tmp/hcp_cli

echo "$(date) Destroying hosted cluster ${HC_NAME} in namespace ${HC_NS}"
hcp destroy cluster kubevirt \
  --name "${HC_NAME}" \
  --namespace "${HC_NS}" || true

echo "$(date) Deleting namespace ${HC_NS} if it still exists"
oc delete ns "${HC_NS}" --ignore-not-found=true || true

echo "$(date) Hosted cluster ${HC_NAME} destroyed"
