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
oc get nodes -o wide
echo "oc get co"
oc get co
echo "oc get mce"
oc get mce
echo "oc get po -n openshift-cnv"
oc get po -n openshift-cnv
echo "oc get sc"
oc get sc
echo "oc get po -n metallb-system"
oc get po -n metallb-system
echo "oc get ipaddresspool -A"
oc get ipaddresspool -A

echo ""
echo "============================================================"
echo "Infra cluster nodes (KUBECONFIG=${INFRA_KUBECONFIG})"
echo "============================================================"
export KUBECONFIG="${INFRA_KUBECONFIG}"
echo "oc get nodes -o wide"
oc get nodes -o wide
echo "oc get co"
oc get co
echo "oc get po -n openshift-cnv"
oc get po -n openshift-cnv
echo "oc get sc"
oc get sc
echo "oc get po -n metallb-system"
oc get po -n metallb-system
echo "oc get ipaddresspool -A"
oc get ipaddresspool -A


echo ""
echo "============================================================"
echo "HCP Kubevirt - Ext Infra"
echo "============================================================"
export KUBECONFIG="${MGMT_KUBECONFIG}"
echo "oc get hc -A"
oc get hc -A
echo "oc get po -n hcpvirt-oz-ci-ns-hcpvirt-oz-ci"
oc get po -n hcpvirt-oz-ci-ns-hcpvirt-oz-ci
echo "oc get np -A"
oc get np -A

export KUBECONFIG="${INFRA_KUBECONFIG}"
echo "oc get vmi -A"
oc get vmi -A
echo "oc get svc -n ext-infra-vms-ns"
oc get svc -n ext-infra-vms-ns