#!/bin/bash

set -euo pipefail

SCRIPT_EXIT_CODE=0

# Cluster credentials — try Prow shared dir (AWS), then Vault (PerfLab)
if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/kubeadmin-password" ]]; then
  KUBEADMIN_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
  export KUBEADMIN_PASSWORD
elif [[ -s /secret/kubeadmin_password ]]; then
  KUBEADMIN_PASSWORD=$(<"/secret/kubeadmin_password")
  KUBEADMIN_PASSWORD="${KUBEADMIN_PASSWORD%$'\n'}"
  export KUBEADMIN_PASSWORD
fi

if [[ -f /var/run/secrets/ci.openshift.io/multi-stage/kubeconfig ]]; then
  cp /var/run/secrets/ci.openshift.io/multi-stage/kubeconfig /tmp/kubeconfig
  export KUBECONFIG=/tmp/kubeconfig
elif [[ -s /secret/kubeconfig ]]; then
  cp /secret/kubeconfig /tmp/kubeconfig
  export KUBECONFIG=/tmp/kubeconfig
  echo "Using kubeconfig from Vault secret"
else
  echo "ERROR: no kubeconfig found (checked multi-stage and /secret/kubeconfig)" >&2
  exit 1
fi

# Vault secrets
if [[ -d /secret ]]; then
  echo "=== Vault secret mounted at /secret ==="
  ls -la /secret 2>/dev/null || true
  for key in base_domain elasticsearch elasticsearch_port lso_disk_id \
             redis threads_limit lso_node worker_disk_prefix scale_nodes windows_url \
             pin_node1 pin_node2; do
    upper_key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
    if [[ -s "/secret/${key}" ]] && [[ -z "${!upper_key:-}" ]]; then
      val=$(<"/secret/${key}")
      val="${val%$'\n'}"
      export "${upper_key}=${val}"
    fi
  done
fi

# Debug on exit
benchmark_runner_debug() {
  local _code=$?
  if [[ $_code -ne 0 || "${SCRIPT_EXIT_CODE:-0}" -ne 0 ]]; then
    echo "=== benchmark-runner namespace state (debug) ==="
    oc get all -n benchmark-runner 2>&1 || true
    echo "=== benchmark-runner events ==="
    oc get events -n benchmark-runner --sort-by='.lastTimestamp' 2>&1 || true
    if [[ "${WORKLOAD:-}" == *"_vm"* ]]; then
      echo "=== VMI ==="
      oc get vmi -n benchmark-runner -o yaml 2>&1 || true
    fi
  fi
}
trap benchmark_runner_debug EXIT

oc create namespace benchmark-runner 2>/dev/null || true

# For LSO workloads: ensure PV exists and database lands on same node
if [[ "${WORKLOAD:-}" == *"_lso"* ]] && [[ -n "${LSO_DISK_ID:-}" ]] && [[ -n "${LSO_NODE:-}" ]]; then
  export PIN_NODE2="${LSO_NODE}"
  oc login -u kubeadmin -p "${KUBEADMIN_PASSWORD}" 2>/dev/null || true
  # Clean up Released/Available local-sc PVs and stuck finalizers from previous runs
  for pv in $(oc get pv --no-headers 2>/dev/null | grep -E "Released|Available" | grep local-sc | awk '{print $1}'); do
    oc patch pv "$pv" --type=json -p='[{"op":"remove","path":"/metadata/finalizers/0"}]' 2>/dev/null || true
    oc delete pv "$pv" --wait=false 2>/dev/null || true
  done
  sleep 5
  DISK_PREFIX="${WORKER_DISK_PREFIX:-wwn-0x}"
  if ! oc get storageclass local-sc &>/dev/null; then
    oc apply -f - <<SCEOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-sc
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
SCEOF
  fi
  # Delete existing LocalVolume CR to ensure correct volumeMode for this run
  oc delete localvolume local-disks -n openshift-local-storage --wait=false 2>/dev/null || true
  sleep 3
  if [[ "${WORKLOAD:-}" == *"_vm_"* || "${WORKLOAD:-}" == *"_vm" ]]; then
    oc apply -f - <<LVEOF
apiVersion: local.storage.openshift.io/v1
kind: LocalVolume
metadata:
  name: local-disks
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
    - matchExpressions:
      - key: kubernetes.io/hostname
        operator: In
        values:
        - ${LSO_NODE}
  storageClassDevices:
  - storageClassName: local-sc
    volumeMode: Block
    devicePaths:
    - /dev/disk/by-id/${DISK_PREFIX}${LSO_DISK_ID}
LVEOF
  else
    oc apply -f - <<LVEOF
apiVersion: local.storage.openshift.io/v1
kind: LocalVolume
metadata:
  name: local-disks
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
    - matchExpressions:
      - key: kubernetes.io/hostname
        operator: In
        values:
        - ${LSO_NODE}
  storageClassDevices:
  - storageClassName: local-sc
    volumeMode: Filesystem
    fsType: ext4
    devicePaths:
    - /dev/disk/by-id/${DISK_PREFIX}${LSO_DISK_ID}
LVEOF
  fi
  for _wait in $(seq 1 30); do
    oc get pv 2>/dev/null | grep -q local-sc && break
    sleep 5
  done
fi

# For VM workloads: wait for KubeVirt readiness
if [[ "${WORKLOAD:-}" == *"_vm"* ]] && oc get daemonset virt-handler -n openshift-cnv 2>/dev/null; then
  echo "=== Pre-flight: KubeVirt readiness ==="
  oc rollout status daemonset/virt-handler -n openshift-cnv --timeout=5m
  oc rollout status deployment/virt-controller -n openshift-cnv --timeout=3m
  oc rollout status deployment/virt-api -n openshift-cnv --timeout=3m
  sleep 180
  echo "  $(oc get nodes -l kubevirt.io/schedulable=true -o name 2>/dev/null | wc -l) nodes with kubevirt.io/schedulable=true"
  echo "=== Pre-flight complete ==="
fi

echo "=== Python start: $(date -Iseconds) ==="

# For VM workloads: monitor pod state in background
MONITOR_PID=""
if [[ "${WORKLOAD:-}" == *"_vm"* ]]; then
  (
    sleep 60
    while true; do
      echo "=== VM-MONITOR $(date -Iseconds) ==="
      oc get pods -n benchmark-runner -o wide 2>/dev/null || true
      oc get events -n benchmark-runner --sort-by='.lastTimestamp' 2>/dev/null | tail -3 || true
      echo "=== END ==="
      sleep 30
    done
  ) &
  MONITOR_PID=$!
fi

rc=0
if [[ "${WORKLOAD:-}" == *"_lso"* ]]; then
  python3.14 -c "
import benchmark_runner.common.oc.oc as oc_mod
oc_mod.OC.delete_available_released_pv = lambda self: None
exec(open('/benchmark_runner/main/main.py').read())
" || rc=$?
else
  python3.14 /benchmark_runner/main/main.py || rc=$?
fi
SCRIPT_EXIT_CODE=$rc

if [[ -n "$MONITOR_PID" ]]; then
  kill $MONITOR_PID 2>/dev/null || true
  wait $MONITOR_PID 2>/dev/null || true
fi

echo "=== Python end: $(date -Iseconds) exit_code: $rc ==="
if [ $rc -ne 0 ] && [[ -n "${ARTIFACT_DIR:-}" ]]; then
  mkdir -p "${ARTIFACT_DIR}/benchmark-runner-debug"
  oc get all -n benchmark-runner > "${ARTIFACT_DIR}/benchmark-runner-debug/all.yaml" 2>&1 || true
  oc get events -n benchmark-runner --sort-by='.lastTimestamp' > "${ARTIFACT_DIR}/benchmark-runner-debug/events.txt" 2>&1 || true
fi
echo "benchmark-runner exit code: $rc"
exit $SCRIPT_EXIT_CODE
