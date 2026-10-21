#!/bin/bash

set -xuo pipefail
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
mkdir -p ${ARTIFACT_DIR}/cilium-debug

oc get ciliumclusterwidenetworkpolicy -A -o yaml > ${ARTIFACT_DIR}/cilium-debug/ciliumclusterwidenetworkpolicies.yaml 2>&1 || true
oc get ciliumendpoint -A > ${ARTIFACT_DIR}/cilium-debug/ciliumendpoints.txt 2>&1 || true
oc get ciliumconfig -n cilium -o yaml > ${ARTIFACT_DIR}/cilium-debug/ciliumconfig.yaml 2>&1 || true

CILIUM_POD=$(oc get pods -n cilium -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
if [[ -n "${CILIUM_POD}" ]]; then
  oc exec -n cilium ${CILIUM_POD} -- cilium status > ${ARTIFACT_DIR}/cilium-debug/cilium-status.txt 2>&1 || true
  oc exec -n cilium ${CILIUM_POD} -- cilium service list > ${ARTIFACT_DIR}/cilium-debug/cilium-service-list.txt 2>&1 || true
  oc exec -n cilium ${CILIUM_POD} -- cilium bpf lb list > ${ARTIFACT_DIR}/cilium-debug/cilium-bpf-lb-list.txt 2>&1 || true
  oc exec -n cilium ${CILIUM_POD} -- cilium config > ${ARTIFACT_DIR}/cilium-debug/cilium-config.txt 2>&1 || true
fi
