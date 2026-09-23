#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

if [ ! -f "${KUBECONFIG}" ]; then
  echo "No nested kubeconfig, skipping FIPS check."
  exit 0
fi

echo "Checking FIPS mode on all hosted cluster nodes..."
failed=0
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  fips=$(oc debug node/"${node}" -- cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo "error")
  if [[ "${fips}" == "1" ]]; then
    echo "  ${node}: FIPS enabled"
  else
    echo "  ${node}: FIPS NOT enabled (got: ${fips})"
    failed=1
  fi
done

if [[ "${failed}" == "1" ]]; then
  echo "FIPS check FAILED"
  exit 1
fi
echo "FIPS check PASSED on all nodes"
