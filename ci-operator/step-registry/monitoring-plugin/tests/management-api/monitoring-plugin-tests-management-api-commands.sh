#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# The plugin binary runs in this step pod on the build cluster. KUBECONFIG
# points at the test cluster, but thanos-querier.openshift-monitoring.svc
# would otherwise resolve to the build cluster, and kubeconfig CAData is the
# API server CA rather than the test cluster service CA. User-namespace
# rules and alerts also require user workload monitoring.

PORT=9001
THANOS_LOCAL_PORT=9093

unset GOFLAGS
export GOCACHE=/tmp/go-build
export GOMODCACHE=/tmp/go-mod

merge_enable_user_workload() {
  local current="$1"
  if printf '%s\n' "${current}" | grep -Eq '^enableUserWorkload:[[:space:]]*true[[:space:]]*$'; then
    printf '%s\n' "${current}"
    return 0
  fi
  if printf '%s\n' "${current}" | grep -Eq '^enableUserWorkload:'; then
    printf '%s\n' "${current}" | sed -E 's/^enableUserWorkload:.*/enableUserWorkload: true/'
    return 0
  fi
  if [ -z "${current}" ]; then
    printf 'enableUserWorkload: true\n'
    return 0
  fi
  printf '%s\nenableUserWorkload: true\n' "${current}"
}

enable_user_workload_monitoring() {
  echo "Ensuring user workload monitoring is enabled..."
  local current="" cfg_file
  if oc -n openshift-monitoring get configmap cluster-monitoring-config >/dev/null 2>&1; then
    current=$(oc -n openshift-monitoring get configmap cluster-monitoring-config -o jsonpath='{.data.config\.yaml}')
  fi
  cfg_file=$(mktemp)
  merge_enable_user_workload "${current}" > "${cfg_file}"
  oc -n openshift-monitoring create configmap cluster-monitoring-config \
    --from-file=config.yaml="${cfg_file}" \
    --dry-run=client -o yaml | oc apply -f -

  echo "Waiting for user-workload Prometheus..."
  local i
  for i in $(seq 1 60); do
    if oc -n openshift-user-workload-monitoring get statefulset prometheus-user-workload >/dev/null 2>&1; then
      oc -n openshift-user-workload-monitoring rollout status statefulset/prometheus-user-workload --timeout=15m
      oc -n openshift-monitoring rollout status deployment/thanos-querier --timeout=10m
      return 0
    fi
    echo "  attempt ${i}/60 waiting for prometheus-user-workload StatefulSet..."
    sleep 10
  done
  echo "ERROR: prometheus-user-workload StatefulSet did not appear"
  return 1
}

prepare_kubeconfig_with_service_ca() {
  local ca_dir ca_file raw_kc cluster server ca_data ca_path service_ca
  ca_dir=$(mktemp -d)
  ca_file="${ca_dir}/ca.crt"
  raw_kc="${ca_dir}/kubeconfig"

  oc config view --raw --minify > "${raw_kc}"
  cluster=$(KUBECONFIG="${raw_kc}" oc config view --raw --minify -o jsonpath='{.clusters[0].name}')
  server=$(KUBECONFIG="${raw_kc}" oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
  if [ -z "${cluster}" ] || [ -z "${server}" ]; then
    echo "ERROR: could not read kubeconfig cluster name or server"
    return 1
  fi

  ca_data=$(KUBECONFIG="${raw_kc}" oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  ca_path=$(KUBECONFIG="${raw_kc}" oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}')
  if [ -n "${ca_data}" ]; then
    printf '%s' "${ca_data}" | base64 -d > "${ca_file}"
  elif [ -n "${ca_path}" ]; then
    cat "${ca_path}" > "${ca_file}"
  else
    echo "ERROR: kubeconfig has no API server CA"
    return 1
  fi
  if ! grep -q 'BEGIN CERTIFICATE' "${ca_file}"; then
    echo "ERROR: API server CA bundle is empty"
    return 1
  fi

  service_ca=$(mktemp)
  oc -n openshift-config-managed get configmap openshift-service-ca.crt \
    -o jsonpath='{.data.ca-bundle\.crt}' > "${service_ca}"
  if ! grep -q 'BEGIN CERTIFICATE' "${service_ca}"; then
    echo "ERROR: test cluster service CA bundle is empty"
    return 1
  fi
  printf '\n' >> "${ca_file}"
  cat "${service_ca}" >> "${ca_file}"

  KUBECONFIG="${raw_kc}" oc config set-cluster "${cluster}" \
    --server="${server}" \
    --certificate-authority="${ca_file}" \
    --embed-certs=true >/dev/null

  export KUBECONFIG="${raw_kc}"
  # Honored by plugin builds that read this env. Embedding the service CA in
  # kubeconfig CAData also covers builds that only trust CAData.
  export MONITORING_PLUGIN_SERVICE_CA_FILE="${ca_file}"
}

forward_thanos_tenancy() {
  local pf_pid_file="$1"
  while true; do
    oc -n openshift-monitoring port-forward --address 127.0.0.1 \
      svc/thanos-querier "${THANOS_LOCAL_PORT}:9093" &
    echo "$!" > "${pf_pid_file}"
    wait "$!" || true
    sleep 1
  done
}

echo "Preparing kubeconfig with the test cluster service CA..."
prepare_kubeconfig_with_service_ca

enable_user_workload_monitoring &
UW_PID=$!

cleanup() {
  if [ -n "${UW_PID:-}" ]; then
    kill "${UW_PID}" 2>/dev/null || true
  fi
  if [ -n "${BACKEND_PID:-}" ]; then
    kill "${BACKEND_PID}" 2>/dev/null || true
  fi
  if [ -n "${PF_PID_FILE:-}" ] && [ -s "${PF_PID_FILE}" ]; then
    kill "$(cat "${PF_PID_FILE}")" 2>/dev/null || true
  fi
  if [ -n "${PF_LOOP_PID:-}" ]; then
    kill "${PF_LOOP_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "Building monitoring-plugin backend..."
go build -o /tmp/plugin-backend ./cmd/plugin-backend.go

if ! wait "${UW_PID}"; then
  echo "ERROR: user workload monitoring did not become ready"
  exit 1
fi
UW_PID=""

hosts_line="127.0.0.1 thanos-querier.openshift-monitoring.svc thanos-querier.openshift-monitoring.svc.cluster.local"
if ! grep -q 'thanos-querier.openshift-monitoring.svc' /etc/hosts; then
  echo "${hosts_line}" >> /etc/hosts
fi

PF_PID_FILE=$(mktemp)
forward_thanos_tenancy "${PF_PID_FILE}" &
PF_LOOP_PID=$!

echo "Waiting for thanos-querier port-forward..."
forward_ready=false
for i in $(seq 1 30); do
  if bash -c "echo >/dev/tcp/127.0.0.1/${THANOS_LOCAL_PORT}" 2>/dev/null; then
    echo "thanos-querier port-forward is ready"
    forward_ready=true
    break
  fi
  echo "  attempt ${i}/30..."
  sleep 1
done
if [ "${forward_ready}" != "true" ]; then
  echo "ERROR: thanos-querier port-forward did not become ready"
  exit 1
fi

echo "Starting monitoring-plugin backend on port ${PORT}..."
/tmp/plugin-backend \
  -port="${PORT}" \
  -config-path="./config" \
  -static-path="./web/dist" \
  -features='alert-management-api' &
BACKEND_PID=$!

echo "Waiting for backend to be ready..."
ready=false
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${PORT}/health" > /dev/null 2>&1; then
    echo "Backend is ready"
    ready=true
    break
  fi
  echo "  attempt ${i}/30..."
  sleep 2
done

if [ "${ready}" != "true" ]; then
  echo "ERROR: Backend did not become ready after 30 attempts"
  exit 1
fi

echo "Running management API e2e tests..."
export PLUGIN_URL="http://localhost:${PORT}"

make test-e2e
