#!/bin/bash

set -euo pipefail

export PATH="/hypershift/bin:${PATH}"
export E2E_HOSTED_CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"
export E2E_HOSTED_CLUSTER_NAMESPACE="${E2E_HOSTED_CLUSTER_NAMESPACE:-local-cluster}"
export KUBECONFIG_SOURCE="${SHARED_DIR}/management_cluster_kubeconfig_source"
export KUBECONFIG_TARGET="${SHARED_DIR}/management_cluster_kubeconfig_target"
export KUBECONFIG="${KUBECONFIG_SOURCE}"
export KUBEVIRT_CROSS_CLUSTER_DNS_HOOK="${SHARED_DIR}/cross-cluster-dns-hook.sh"

test -s "${KUBECONFIG_SOURCE}"
test -s "${KUBECONFIG_TARGET}"
test -x "${KUBEVIRT_CROSS_CLUSTER_DNS_HOOK}"
command -v oc >/dev/null
command -v ssh >/dev/null
source_platform="$(oc --kubeconfig="${KUBECONFIG_SOURCE}" get hostedcluster "${E2E_HOSTED_CLUSTER_NAME}" \
  -n "${E2E_HOSTED_CLUSTER_NAMESPACE}" -o jsonpath='{.spec.platform.type}')"
[[ "${source_platform}" == KubeVirt ]] || { echo "Source HostedCluster must use KubeVirt" >&2; exit 1; }
source_host="$(<"${SHARED_DIR}/ofcir-source-server-ip")"
target_host="$(<"${SHARED_DIR}/ofcir-target-server-ip")"
[[ -n "${source_host}" && -n "${target_host}" && "${source_host}" != "${target_host}" ]] || {
  echo "Source and target must lease different OFCIR hosts" >&2
  exit 1
}
target_proxy_port="$(awk -F= '/^export PROXYPORT=/{print $2}' "${SHARED_DIR}/proxy-conf.sh")"
[[ "${target_proxy_port}" =~ ^[0-9]+$ ]] || { echo "Missing target proxy port" >&2; exit 1; }
export KUBEVIRT_TARGET_GUEST_PROXY="http://${target_host}:${target_proxy_port}"
test-backuprestore \
  --ginkgo.v \
  --ginkgo.junit-report="${ARTIFACT_DIR}/junit_cross_cluster_restore_report.xml" \
  --ginkgo.label-filter="cross-cluster-restore" \
  --ginkgo.fail-fast=true \
  --ginkgo.fail-on-empty=true \
  --ginkgo.timeout=5h \
  --ginkgo.no-color=true
