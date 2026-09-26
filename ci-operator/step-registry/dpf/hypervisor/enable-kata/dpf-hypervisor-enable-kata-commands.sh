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

echo "=== Verifying cluster access ==="
oc get nodes -o wide

echo "=== Enabling the Kata OVN injector mapping ==="
make enable-ovn-injector

echo "=== Enabling Kata DPU cold-plug ==="
make enable-kata
