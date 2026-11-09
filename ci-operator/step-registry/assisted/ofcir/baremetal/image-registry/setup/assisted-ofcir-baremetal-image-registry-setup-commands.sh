#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted ofcir baremetal image registry setup command ************"

if [[ "${TEST_TYPE:-none}" == "none" ]]; then
  echo "TEST_TYPE is 'none', skipping image registry setup."
  exit 0
fi

echo "TEST_TYPE=${TEST_TYPE}: enabling cluster image registry (Managed + emptyDir)"

timeout -s 9 30m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - <<'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -euo pipefail
cd /home/assisted
source /root/config.sh

kubeconfig_dir=/home/assisted/build/kubeconfig
declare -a kubeconfig_files=()
if [[ -d "${kubeconfig_dir}" ]]; then
  while IFS= read -r kc; do
    kubeconfig_files+=("${kc}")
  done < <(find "${kubeconfig_dir}" -type f | sort)
  if [[ ${#kubeconfig_files[@]} -eq 0 ]]; then
    echo "FATAL: directory ${kubeconfig_dir} contains no kubeconfig files"
    exit 1
  fi
elif [[ -f "${kubeconfig_dir}" ]]; then
  kubeconfig_files=("${kubeconfig_dir}")
else
  echo "FATAL: kubeconfig path ${kubeconfig_dir} does not exist"
  exit 1
fi

dump_image_registry_debug() {
  echo "===== image-registry debug ====="
  oc get configs.imageregistry.operator.openshift.io cluster -o yaml || true
  oc get co image-registry -o yaml || true
  oc get pods -n openshift-image-registry -o wide || true
  oc get events -n openshift-image-registry --sort-by=.lastTimestamp | tail -50 || true
}

patch_image_registry() {
  # emptyDir is node-local: multi-node clusters default to replicas>1, which leaves
  # image-registry unavailable. Force replicas=1 + Recreate (OpenShift requirement).
  # Pin to masters (day2 workers must not steal emptyDir state) and tolerate the
  # master NoSchedule taint — nodeSelector alone leaves pods Pending on HA.
  until oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
    --patch '{"spec":{"managementState":"Managed","replicas":1,"rolloutStrategy":"Recreate","storage":{"emptyDir":{}},"nodeSelector":{"node-role.kubernetes.io/master":""},"tolerations":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/master","operator":"Exists"}]}}'
  do
    echo "$(date --rfc-3339=seconds) Failed to patch image registry configuration. Retrying..."
    sleep 15
  done
}

wait_cluster_operators() {
  local deadline=$((SECONDS + 25 * 60))
  until \
    oc wait --all=true clusteroperators --for=condition=Available=True --timeout=2m >/dev/null && \
    oc wait --all=true clusteroperators --for=condition=Progressing=False --timeout=2m >/dev/null && \
    oc wait --all=true clusteroperators --for=condition=Degraded=False --timeout=2m >/dev/null
  do
    if (( SECONDS >= deadline )); then
      echo "$(date --rfc-3339=seconds) FATAL: clusteroperators not ready before deadline"
      dump_image_registry_debug
      return 1
    fi
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    sleep 1s
  done
}

for kc in "${kubeconfig_files[@]}"; do
  export KUBECONFIG="${kc}"
  echo "===== configuring image registry with KUBECONFIG=${KUBECONFIG} ====="
  patch_image_registry
  echo "$(date -u --rfc-3339=seconds) - Image registry configuration patched"
  wait_cluster_operators
  echo "$(date --rfc-3339=seconds) Clusteroperators ready"
done
EOF
