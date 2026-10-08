#!/bin/bash
set -euo pipefail

cd /root/dpf-ci
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "ERROR: kubeconfig not found at ${KUBECONFIG}"
  exit 1
fi
if [[ ! -f "${SHARED_DIR}/.env" ]]; then
  echo "ERROR: .env not found at ${SHARED_DIR}/.env"
  exit 1
fi

cp "${SHARED_DIR}/.env" .env

set_env() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" .env; then
    sed -i -E "s|^${key}=.*$|${key}=${value}|" .env
  else
    printf '%s=%s\n' "${key}" "${value}" >> .env
  fi
}

set_env KUBECONFIG "${KUBECONFIG}"
set_env KATA_ENABLED true
set_env KATA_TEST_REPLICAS 1

echo "=== Verifying cluster access ==="
oc get nodes -o wide

echo "=== Enabling the Kata OVN injector mapping ==="
make enable-ovn-injector

echo "=== Enabling Kata DPU cold-plug ==="
make enable-kata

echo "=== Deploying one Kata smoke-test pod ==="
make deploy-kata-test

echo "=== Verifying the Kata smoke-test pod is Ready ==="
oc wait --for=condition=Ready pod -l app=kata-dpu-test --timeout=10m

pod_name="$(oc get pods -l app=kata-dpu-test --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "${pod_name}" ]]; then
  echo "ERROR: no Running kata-dpu-test pod found"
  oc get pods -l app=kata-dpu-test -o wide
  exit 1
fi

pod_phase="$(oc get pod "${pod_name}" -o jsonpath='{.status.phase}')"
pod_ready="$(oc get pod "${pod_name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
runtime_class="$(oc get pod "${pod_name}" -o jsonpath='{.spec.runtimeClassName}')"
if [[ "${pod_phase}" != "Running" || "${pod_ready}" != "True" || -z "${runtime_class}" ]]; then
  echo "ERROR: Kata smoke-test pod ${pod_name} is not Running and Ready with a runtime class"
  oc get pod "${pod_name}" -o wide
  exit 1
fi

echo "Kata smoke-test pod ${pod_name} is Running and Ready (runtimeClass=${runtime_class})"
oc get pod "${pod_name}" -o wide
