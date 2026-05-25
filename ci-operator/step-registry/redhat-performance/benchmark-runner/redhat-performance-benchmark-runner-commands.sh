#!/bin/bash

set -euo pipefail

SCRIPT_EXIT_CODE=0

# Cluster credentials from Vault
if [[ -s /secret/kubeadmin_password ]]; then
  KUBEADMIN_PASSWORD=$(<"/secret/kubeadmin_password")
  KUBEADMIN_PASSWORD="${KUBEADMIN_PASSWORD%$'\n'}"
  export KUBEADMIN_PASSWORD
fi

if [[ -s /secret/kubeconfig ]]; then
  cp /secret/kubeconfig /tmp/kubeconfig
  export KUBECONFIG=/tmp/kubeconfig
  echo "Using kubeconfig from Vault secret"

  # SOCKS proxy for private VLAN clusters (API on 198.18.x.x)
  CLUSTER_SERVER=$(oc config view --kubeconfig=/tmp/kubeconfig --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  if [[ -s /secret/bastion_address ]] && [[ -s /secret/jh_priv_ssh_key ]]; then
    BASTION_ADDRESS=$(<"/secret/bastion_address")
    BASTION_ADDRESS="${BASTION_ADDRESS%$'\n'}"
    cp /secret/jh_priv_ssh_key /tmp/bastion_key
    chmod 600 /tmp/bastion_key
    if ! curl -sk --max-time 5 "${CLUSTER_SERVER}/version" &>/dev/null; then
      echo "API not directly reachable, starting SOCKS proxy through ${BASTION_ADDRESS}"
      SSH_ARGS="-i /tmp/bastion_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
      SOCKS_PORT=$((RANDOM % 55536 + 10000))
      ES_PORT=$(<"/secret/elasticsearch_port")
      ES_PORT="${ES_PORT%$'\n'}"
      ssh ${SSH_ARGS} root@"${BASTION_ADDRESS}" -fNT -D "${SOCKS_PORT}" -L "127.0.0.1:${ES_PORT}:localhost:${ES_PORT}"
      sleep 3
      export HTTPS_PROXY="socks5h://localhost:${SOCKS_PORT}"
      export https_proxy="socks5h://localhost:${SOCKS_PORT}"
      export HTTP_PROXY="socks5h://localhost:${SOCKS_PORT}"
      export http_proxy="socks5h://localhost:${SOCKS_PORT}"
      export ELASTICSEARCH=localhost
      echo "SOCKS proxy on port ${SOCKS_PORT}, ES tunnel on port ${ES_PORT}"
    else
      echo "API directly reachable, no SOCKS proxy needed"
    fi
  fi
else
  echo "ERROR: no kubeconfig found at /secret/kubeconfig" >&2
  exit 1
fi

# Vault secrets
if [[ -d /secret ]]; then
  echo "=== Vault secret mounted at /secret ==="
  ls -la /secret 2>/dev/null || true
  for key in base_domain elasticsearch elasticsearch_port lso_disk_id worker_disk_ids \
             redis threads_limit lso_node worker_disk_prefix scale_nodes windows_url \
             winmssql_url windows_server_2022_url windows_server_2025_url \
             pin_node0 pin_node1 pin_node2 bastion_address; do
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

# Per-workload Windows image override
if [[ "${WORKLOAD:-}" == "winmssql_vm" ]] && [[ -n "${WINMSSQL_URL:-}" ]]; then
  export WINDOWS_URL="${WINMSSQL_URL}"
elif [[ -n "${WINDOWS_IMAGE:-}" ]]; then
  case "${WINDOWS_IMAGE}" in
    windows_server_2022) [[ -n "${WINDOWS_SERVER_2022_URL:-}" ]] && export WINDOWS_URL="${WINDOWS_SERVER_2022_URL}" ;;
    windows_server_2025) [[ -n "${WINDOWS_SERVER_2025_URL:-}" ]] && export WINDOWS_URL="${WINDOWS_SERVER_2025_URL}" ;;
  esac
fi

BUILD_VERSION=$(curl -s "https://pypi.org/pypi/benchmark-runner/json" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" 2>/dev/null || echo "1.0.0")
export BUILD_VERSION

echo "=== Python start: $(date -Iseconds) ==="

if [[ "${WORKLOAD}" == "all" ]]; then
  ALL_WORKLOADS=(
    sysbench_pod sysbench_vm uperf_pod uperf_vm
    hammerdb_pod_mariadb hammerdb_vm_mariadb
    hammerdb_pod_mariadb_lso hammerdb_vm_mariadb_lso
    hammerdb_pod_postgres hammerdb_vm_postgres
    hammerdb_pod_postgres_lso hammerdb_vm_postgres_lso
    hammerdb_pod_mssql hammerdb_vm_mssql
    hammerdb_pod_mssql_lso hammerdb_vm_mssql_lso
    fio_pod fio_vm
    fio_pod_scale fio_vm_scale
    vdbench_pod vdbench_vm
    vdbench_pod_scale vdbench_vm_scale
    bootstorm_vm_scale
    winmssql_vm
    windows_vm_scale_windows11
    windows_vm_scale_windows_server_2022
    windows_vm_scale_windows_server_2025
  )
  SAVED_WINDOWS_URL="${WINDOWS_URL:-}"
  FAILED=""
  for wl in "${ALL_WORKLOADS[@]}"; do
    echo "=== $(date -Iseconds) Running: $wl ==="
    export WORKLOAD=$wl

    # Per-workload SCALE + WORKLOAD override (benchmark-runner uses base name without _scale suffix)
    case "$wl" in
      vdbench_pod_scale) export SCALE=2; export WORKLOAD=vdbench_pod ;;
      vdbench_vm_scale) export SCALE=2; export WORKLOAD=vdbench_vm ;;
      fio_pod_scale) export SCALE=2; export WORKLOAD=fio_pod ;;
      fio_vm_scale) export SCALE=2; export WORKLOAD=fio_vm ;;
      bootstorm_vm_scale) export SCALE=80; export WORKLOAD=bootstorm_vm ;;
      windows_vm_scale_*) export SCALE=37 ;;
      *) export SCALE="" ;;
    esac

    # Per-workload Windows image override
    export WINDOWS_URL="${SAVED_WINDOWS_URL}"
    export WINDOWS_IMAGE=""
    case "$wl" in
      winmssql_vm) [[ -n "${WINMSSQL_URL:-}" ]] && export WINDOWS_URL="${WINMSSQL_URL}" ;;
      windows_vm_scale_windows11) export WINDOWS_IMAGE=windows11; export WORKLOAD=windows_vm ;;
      windows_vm_scale_windows_server_2022) export WINDOWS_IMAGE=windows_server_2022; export WORKLOAD=windows_vm; [[ -n "${WINDOWS_SERVER_2022_URL:-}" ]] && export WINDOWS_URL="${WINDOWS_SERVER_2022_URL}" ;;
      windows_vm_scale_windows_server_2025) export WINDOWS_IMAGE=windows_server_2025; export WORKLOAD=windows_vm; [[ -n "${WINDOWS_SERVER_2025_URL:-}" ]] && export WINDOWS_URL="${WINDOWS_SERVER_2025_URL}" ;;
    esac

    python3.14 /benchmark_runner/main/main.py && echo "=== PASSED: $wl ===" || { echo "=== FAILED: $wl ==="; FAILED="${FAILED} ${wl}"; }

    # Full cleanup: delete namespace to remove all resources (pods, PVCs, DVs, VMs, configmaps)
    oc delete namespace benchmark-runner --timeout=300s 2>/dev/null || true
    while oc get namespace benchmark-runner 2>/dev/null | grep -q Terminating; do sleep 5; done
    oc create namespace benchmark-runner 2>/dev/null || true
  done
  echo "=== ALL DONE at $(date -Iseconds) ==="
  if [[ -n "$FAILED" ]]; then
    echo "FAILED WORKLOADS:${FAILED}"
    SCRIPT_EXIT_CODE=1
  fi
else
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
  python3.14 /benchmark_runner/main/main.py || rc=$?
  SCRIPT_EXIT_CODE=$rc

  if [[ -n "$MONITOR_PID" ]]; then
    kill $MONITOR_PID 2>/dev/null || true
    wait $MONITOR_PID 2>/dev/null || true
  fi
fi

echo "=== Python end: $(date -Iseconds) exit_code: ${rc:-$SCRIPT_EXIT_CODE} ==="
if [ "${rc:-$SCRIPT_EXIT_CODE}" -ne 0 ] && [[ -n "${ARTIFACT_DIR:-}" ]]; then
  mkdir -p "${ARTIFACT_DIR}/benchmark-runner-debug"
  oc get all -n benchmark-runner > "${ARTIFACT_DIR}/benchmark-runner-debug/all.yaml" 2>&1 || true
  oc get events -n benchmark-runner --sort-by='.lastTimestamp' > "${ARTIFACT_DIR}/benchmark-runner-debug/events.txt" 2>&1 || true
fi
echo "benchmark-runner exit code: ${rc:-$SCRIPT_EXIT_CODE}"
exit $SCRIPT_EXIT_CODE
