#!/bin/bash

set -euo pipefail
# No `set -x`: this step does not handle credentials, but it is a sibling of
# steps that do and the surrounding convention is to keep tracing off.

KUBECONFIG_FILE="${MONITORING_KUBECONFIG:-${SHARED_DIR}/management_cluster_kubeconfig}"
if [[ ! -s "${KUBECONFIG_FILE}" ]]; then
    echo "FATAL: ${KUBECONFIG_FILE} is missing or empty."
    exit 1
fi

k() { oc --kubeconfig="${KUBECONFIG_FILE}" "$@"; }

# A hosted control plane runs as ordinary workloads in a user namespace of the
# management cluster, so its ServiceMonitors are only scraped when user workload
# monitoring is on. The same is true for any operator shipping a ServiceMonitor
# in a namespace the cluster monitoring stack does not own, which is why this is
# a step of its own rather than part of a single workload.
existing=""
if ! existing="$(k -n openshift-monitoring get configmap cluster-monitoring-config \
    -o jsonpath='{.data.config\.yaml}' 2>/dev/null)"; then
    echo "Creating cluster-monitoring-config with user workload monitoring enabled"
    k apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
elif grep -Eq '^[[:space:]]*enableUserWorkload:[[:space:]]*true' <<< "${existing}"; then
    echo "User workload monitoring is already enabled"
else
    echo "Appending enableUserWorkload to the existing cluster-monitoring-config"
    printf '%s\nenableUserWorkload: true\n' "${existing}" > /tmp/cluster-monitoring-config.yaml
    k -n openshift-monitoring create configmap cluster-monitoring-config \
        --from-file=config.yaml=/tmp/cluster-monitoring-config.yaml \
        --dry-run=client -o yaml | k replace -f -
fi

echo "Waiting for the user workload Prometheus StatefulSet to be created"
for _ in $(seq 1 "${UWM_WAIT_ATTEMPTS}"); do
    if k -n openshift-user-workload-monitoring get statefulset prometheus-user-workload >/dev/null 2>&1; then
        break
    fi
    sleep 10
done

k -n openshift-user-workload-monitoring rollout status \
    statefulset/prometheus-user-workload --timeout="${UWM_ROLLOUT_TIMEOUT}"

k -n openshift-user-workload-monitoring get pods \
    > "${ARTIFACT_DIR}/user-workload-monitoring-pods.txt" 2>&1 || true
