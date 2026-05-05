#!/bin/bash

set -xuo pipefail
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
mkdir -p ${ARTIFACT_DIR}/cilium-debug

oc get networkpolicy -A -o yaml > ${ARTIFACT_DIR}/cilium-debug/networkpolicies.yaml 2>&1 || true
oc get ciliumnetworkpolicy -A -o yaml > ${ARTIFACT_DIR}/cilium-debug/ciliumnetworkpolicies.yaml 2>&1 || true
oc get ciliumclusterwidenetworkpolicy -A -o yaml > ${ARTIFACT_DIR}/cilium-debug/ciliumclusterwidenetworkpolicies.yaml 2>&1 || true
oc get ciliumendpoint -A > ${ARTIFACT_DIR}/cilium-debug/ciliumendpoints.txt 2>&1 || true
oc version > ${ARTIFACT_DIR}/cilium-debug/oc-version.txt 2>&1 || true
oc get ns openshift-monitoring -o yaml > ${ARTIFACT_DIR}/cilium-debug/ns-openshift-monitoring.yaml 2>&1 || true
oc get pods -n cilium -o wide > ${ARTIFACT_DIR}/cilium-debug/cilium-pods.txt 2>&1 || true
oc logs -n cilium -l k8s-app=cilium --tail=500 > ${ARTIFACT_DIR}/cilium-debug/cilium-agent-logs.txt 2>&1 || true

# CLB/LoadBalancer debug
oc get svc -A -o wide > ${ARTIFACT_DIR}/cilium-debug/services.txt 2>&1 || true
oc get svc -A -o yaml | grep -A 20 "type: LoadBalancer" > ${ARTIFACT_DIR}/cilium-debug/loadbalancer-svcs.txt 2>&1 || true
oc get endpoints -A > ${ARTIFACT_DIR}/cilium-debug/endpoints.txt 2>&1 || true

# Cilium service handling
CILIUM_POD=$(oc get pods -n cilium -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
if [[ -n "${CILIUM_POD}" ]]; then
  oc exec -n cilium ${CILIUM_POD} -- cilium status > ${ARTIFACT_DIR}/cilium-debug/cilium-status.txt 2>&1 || true
  oc exec -n cilium ${CILIUM_POD} -- cilium service list > ${ARTIFACT_DIR}/cilium-debug/cilium-service-list.txt 2>&1 || true
  oc exec -n cilium ${CILIUM_POD} -- cilium bpf lb list > ${ARTIFACT_DIR}/cilium-debug/cilium-bpf-lb-list.txt 2>&1 || true
  oc exec -n cilium ${CILIUM_POD} -- cilium config | grep -i -E "kube-proxy|nodeport|lb|loadbalancer|masquerade|snat" > ${ARTIFACT_DIR}/cilium-debug/cilium-lb-config.txt 2>&1 || true
fi

# CiliumConfig
oc get ciliumconfig -n cilium -o yaml > ${ARTIFACT_DIR}/cilium-debug/ciliumconfig.yaml 2>&1 || true
