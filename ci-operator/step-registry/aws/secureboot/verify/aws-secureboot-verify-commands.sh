#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${AWS_SECUREBOOT_ENABLED}" != "true" ]]; then
  echo "AWS_SECUREBOOT_ENABLED is not 'true', skipping Secure Boot verification"
  exit 0
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "Verifying UEFI Secure Boot on worker nodes..."

WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker -o name)
if [[ -z "${WORKERS}" ]]; then
  echo "ERROR: No worker nodes found"
  exit 1
fi

FAILED=0
for node in ${WORKERS}; do
  echo "Checking ${node}..."
  SB_STATE=$(oc debug "${node}" -- chroot /host mokutil --sb-state 2>/dev/null || true)
  echo "  ${SB_STATE}"
  if echo "${SB_STATE}" | grep -q "SecureBoot enabled"; then
    echo "  PASS: Secure Boot is enabled"
  else
    echo "  FAIL: Secure Boot is NOT enabled"
    FAILED=1
  fi
done

if [[ "${FAILED}" -eq 1 ]]; then
  echo "ERROR: Secure Boot verification failed on one or more workers"
  exit 1
fi

echo "Secure Boot verification passed on all worker nodes"
