#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MGMT_KUBECONFIG="${SHARED_DIR}/kubeconfig"
INFRA_KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"

echo "============================================================"
echo "Management cluster nodes (KUBECONFIG=${MGMT_KUBECONFIG})"
echo "============================================================"
export KUBECONFIG="${MGMT_KUBECONFIG}"
echo "oc get nodes -o wide"
oc get nodes -o wide || true
echo "oc get co"
oc get co || true
echo "oc get mce"
oc get mce || true
echo "oc get po -n openshift-cnv"
oc get po -n openshift-cnv || true
echo "oc get sc"
oc get sc || true
echo "oc get po -n metallb-system"
oc get po -n metallb-system || true
echo "oc get ipaddresspool -A"
oc get ipaddresspool -A || true

echo ""
echo "============================================================"
echo "Infra cluster nodes (KUBECONFIG=${INFRA_KUBECONFIG})"
echo "============================================================"
if [[ -f "${INFRA_KUBECONFIG}" ]]; then
  export KUBECONFIG="${INFRA_KUBECONFIG}"
  echo "oc get nodes -o wide"
  oc get nodes -o wide || true
  echo "oc get co"
  oc get co || true
  echo "oc get po -n openshift-cnv"
  oc get po -n openshift-cnv || true
  echo "oc get sc"
  oc get sc || true
  echo "oc get po -n metallb-system"
  oc get po -n metallb-system || true
  echo "oc get ipaddresspool -A"
  oc get ipaddresspool -A || true
else
  echo "INFO: ${INFRA_KUBECONFIG} not present — skipping infra dumps (nested topology)"
fi

echo ""
echo "============================================================"
echo "HCP KubeVirt hosted cluster (dynamic name/namespace)"
echo "============================================================"
export KUBECONFIG="${MGMT_KUBECONFIG}"

# Creation steps write PROW_JOB_ID-hash into SHARED_DIR/cluster-name and pick
# HC_NS from the MetalLB pool (hcpvirt-oz-ci-ns vs hcpvirtnew-oz-ci-ns).
HC_NAME=""
if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
  HC_NAME=$(tr -d '[:space:]' < "${SHARED_DIR}/cluster-name")
fi
echo "SHARED_DIR/cluster-name => '${HC_NAME:-<empty>}'"

echo "oc get hc -A"
oc get hc -A -o wide || true

if [[ -z "${HC_NAME}" ]]; then
  HC_NAME=$(oc get hc -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  echo "Fell back to first HostedCluster name: '${HC_NAME:-<empty>}'"
fi

HC_NS=""
HCP_NS=""
if [[ -n "${HC_NAME}" ]]; then
  HC_NS=$(oc get hc -A -o jsonpath="{.items[?(@.metadata.name==\"${HC_NAME}\")].metadata.namespace}" 2>/dev/null || true)
  # Hosted control-plane namespace is <hc-namespace>-<hc-name>
  if [[ -n "${HC_NS}" ]]; then
    HCP_NS="${HC_NS}-${HC_NAME}"
  fi
fi
echo "Resolved HC_NAME=${HC_NAME:-?} HC_NS=${HC_NS:-?} HCP_NS=${HCP_NS:-?}"

if [[ -n "${HCP_NS}" ]]; then
  echo "oc get po -n ${HCP_NS}"
  oc get po -n "${HCP_NS}" -o wide || true
  echo "oc get svc,route -n ${HCP_NS}"
  oc get svc,route -n "${HCP_NS}" -o wide || true
else
  echo "WARNING: could not resolve HCP namespace; dumping all hypershift-looking namespaces"
  oc get ns | grep -E 'hcpvirt|hypershift|clusters-' || true
fi

echo "oc get np -A"
oc get np -A -o wide || true

if [[ -f "${INFRA_KUBECONFIG}" ]]; then
  export KUBECONFIG="${INFRA_KUBECONFIG}"
  echo "oc get vmi -A"
  oc get vmi -A -o wide || true
  echo "oc get svc -n ext-infra-vms-ns"
  oc get svc -n ext-infra-vms-ns || true
else
  # Nested topology: VMIs live on the management cluster
  export KUBECONFIG="${MGMT_KUBECONFIG}"
  echo "oc get vmi -A (mgmt / nested)"
  oc get vmi -A -o wide || true
fi
