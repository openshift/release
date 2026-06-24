#!/bin/bash
set -o nounset
set -o pipefail
source "${SHARED_DIR}/capz-test-env.sh"

# Collect controller logs before cleanup (post step - always runs).
if [[ -n "${USE_KUBECONFIG:-}" && -f "${USE_KUBECONFIG}" ]]; then
  echo "=== Collecting controller logs ==="
  kc="kubectl --kubeconfig=${USE_KUBECONFIG}"
  for ns in capz-system capi-system azureserviceoperator-system; do
    for pod in $($kc get pods -n "$ns" -o name 2>/dev/null); do
      local_logfile="${ARTIFACT_DIR}/${ns}-$(basename "$pod").log"
      $kc logs -n "$ns" "$pod" --all-containers > "$local_logfile" 2>&1 || true
      echo "  saved $local_logfile ($(wc -l < "$local_logfile") lines)"
    done
  done
fi

# Teardown: Safety net cleanup (post step - always runs)
# Cleans up Azure resources created by the test suite (workload cluster, resource groups).
# The management cluster itself is deprovisioned by aks-deprovision.
FORCE=1 make clean-azure
FORCE=1 CS_CLUSTER_NAME="${WORKLOAD_CLUSTER_NAME:-capz-tests}" make clean-azure
