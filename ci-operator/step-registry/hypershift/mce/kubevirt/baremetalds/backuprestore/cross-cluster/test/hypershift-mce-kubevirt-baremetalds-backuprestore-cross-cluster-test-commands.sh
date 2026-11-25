#!/bin/bash

set -euo pipefail

export PATH="/hypershift/bin:${PATH}"
E2E_HOSTED_CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"
export E2E_HOSTED_CLUSTER_NAME
export E2E_HOSTED_CLUSTER_NAMESPACE="${E2E_HOSTED_CLUSTER_NAMESPACE:-local-cluster}"
export KUBECONFIG_SOURCE="${SHARED_DIR}/management_cluster_kubeconfig_source"
export KUBECONFIG_TARGET="${SHARED_DIR}/management_cluster_kubeconfig_target"
export KUBECONFIG="${KUBECONFIG_SOURCE}"

test -s "${KUBECONFIG_SOURCE}"
test -s "${KUBECONFIG_TARGET}"
command -v oc >/dev/null
source_platform="$(oc --kubeconfig="${KUBECONFIG_SOURCE}" get hostedcluster "${E2E_HOSTED_CLUSTER_NAME}" \
  -n "${E2E_HOSTED_CLUSTER_NAMESPACE}" -o jsonpath='{.spec.platform.type}')"
[[ "${source_platform}" == KubeVirt ]] || { echo "Source HostedCluster must use KubeVirt" >&2; exit 1; }
source_host="$(<"${SHARED_DIR}/ofcir-source-server-ip")"
target_host="$(<"${SHARED_DIR}/ofcir-target-server-ip")"
[[ -n "${source_host}" && -n "${target_host}" && "${source_host}" != "${target_host}" ]] || {
  echo "Source and target must lease different OFCIR hosts" >&2
  exit 1
}

build_dir="$(mktemp -d)"
trap 'rm -rf -- "${build_dir}"' EXIT
checkout_dir="${build_dir}/hypershift"
git clone --depth 1 --branch cross-cluster-kubevirt https://github.com/mgencur/hypershift.git "${checkout_dir}"
echo "Building test-backuprestore from $(git -C "${checkout_dir}" rev-parse HEAD)"
GOCACHE="${build_dir}/go-cache" GOMODCACHE="${build_dir}/go-mod-cache" GOMAXPROCS=2 \
  make -C "${checkout_dir}" backuprestore-e2e

"${checkout_dir}/bin/test-backuprestore" \
  --ginkgo.v \
  --ginkgo.junit-report="${ARTIFACT_DIR}/junit_cross_cluster_restore_report.xml" \
  --ginkgo.label-filter="cross-cluster-restore" \
  --ginkgo.fail-fast=true \
  --ginkgo.fail-on-empty=true \
  --ginkgo.timeout=5h \
  --ginkgo.no-color=true
