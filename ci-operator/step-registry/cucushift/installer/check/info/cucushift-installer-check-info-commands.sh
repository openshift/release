#!/bin/bash

set -o nounset
# set -o errexit
# set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
    echo ""
}

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

set +e
run_command "oc get infrastructures.config.openshift.io cluster -oyaml"
run_command "oc get clusterversion/version"
run_command "oc get clusterversion/version -ojson"
run_command "oc get nodes -owide"
run_command "oc get machines.machine.openshift.io -n openshift-machine-api"
run_command "oc get machines.machine.openshift.io -n openshift-machine-api -ojson"
run_command "oc get clusteroperators"
run_command "oc get machineconfig"
run_command "oc get machineconfigpools"
run_command "oc get proxies.config.openshift.io cluster -oyaml"
run_command "oc get networks.config.openshift.io cluster -oyaml"
run_command "oc get networks.operator.openshift.io cluster -oyaml"
run_command "oc get dns.config cluster -oyaml"
run_command "oc -n openshift-ingress-operator get ingresscontroller -oyaml"
run_command "oc -n openshift-ingress get service"
run_command "oc -n openshift-marketplace get catalogsources.operators.coreos.com"
set -e

set -x

MIRROR_PROXY_REGISTRY=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
echo "MIRROR_PROXY_REGISTRY: ${MIRROR_PROXY_REGISTRY}"

ipho_file="/$(mktemp -d)/image-policy-ho.yaml"
cat <<EOF > "$ipho_file"
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: image-policy-ho
spec:
  imageTagMirrors:
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY}/hypershift/hypershift-operator
    source: quay.io/hypershift/hypershift-operator
  - mirrors:
    - ${MIRROR_PROXY_REGISTRY}/hypershift/hypershift-operator
    source: quay.io/rhn_engineering_lgao/hypershift-operator
EOF

run_command "oc apply -f ${ipho_file}"
