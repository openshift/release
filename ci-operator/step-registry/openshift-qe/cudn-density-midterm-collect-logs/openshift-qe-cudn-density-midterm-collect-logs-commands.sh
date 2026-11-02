#!/bin/bash
set -o nounset
set -o pipefail
set -x

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}/midterm-logs"
LOG_DIR="${ARTIFACT_DIR}/midterm-logs"

NODE=$(oc get pods -A --no-headers \
  -o custom-columns=:.metadata.namespace,:.metadata.name,:.spec.nodeName \
  2>/dev/null | grep "cudn-density" | grep "client-1-" | awk '{print $3}' | sort | uniq | head -1)

if [ -z "${NODE}" ]; then
  echo "No client pods found — skipping node-specific log collection"
else
  echo "Client pods on node: ${NODE}"
  POD=$(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node \
    --field-selector "spec.nodeName=${NODE}" \
    -o jsonpath='{.items[0].metadata.name}')
  echo "ovnkube-node pod: ${POD}"

  oc exec -n openshift-ovn-kubernetes "${POD}" -c nbdb -- \
    cat /etc/ovn/ovnnb_db.db > "${LOG_DIR}/ovnnb_db.db" 2>/dev/null || true
  oc exec -n openshift-ovn-kubernetes "${POD}" -c sbdb -- \
    cat /etc/ovn/ovnsb_db.db > "${LOG_DIR}/ovnsb_db.db" 2>/dev/null || true

  {
    echo "=== ovn-controller nre (all) ==="
    oc logs -n openshift-ovn-kubernetes "${POD}" -c ovn-controller 2>/dev/null | grep nre || true
    echo ""
    echo "=== sbdb nre (all) ==="
    oc logs -n openshift-ovn-kubernetes "${POD}" -c sbdb 2>/dev/null | grep nre || true
  } | tee "${LOG_DIR}/nre-all.txt"

  # nre after Group 2 start — key fix validation
  # kube-burner writes log to ARTIFACT_DIR in the workload step
  KB_LOG=$(find "${ARTIFACT_DIR}" -name "kube-burner-ocp-*.log" -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1 || true)
  if [ -n "${KB_LOG}" ]; then
    GROUP2_TS=$(grep "Group 2: Creating object replicas from iteration" "${KB_LOG}" 2>/dev/null \
      | head -1 | awk '{print $1"T"$2}' | tr -d '"' || true)
    echo "Group 2 started at: ${GROUP2_TS}" | tee "${LOG_DIR}/group2-timestamp.txt"
    {
      echo "=== nre AFTER Group 2 start (steady-state — fix validation) ==="
      echo "Group 2 timestamp: ${GROUP2_TS}"
      echo "--- ovn-controller ---"
      oc logs -n openshift-ovn-kubernetes "${POD}" -c ovn-controller 2>/dev/null \
        | grep nre | awk -v ts="${GROUP2_TS}" '$1 >= ts' || true
      echo "--- sbdb ---"
      oc logs -n openshift-ovn-kubernetes "${POD}" -c sbdb 2>/dev/null \
        | grep nre | awk -v ts="${GROUP2_TS}" '$1 >= ts' || true
    } | tee "${LOG_DIR}/nre-after-group2.txt"
    NRE_AFTER=$(grep -c "Unreasonably long" "${LOG_DIR}/nre-after-group2.txt" 2>/dev/null || echo 0)
    echo "RESULT: $([ "${NRE_AFTER}" -eq 0 ] \
      && echo 'PASS - no nre during steady-state ping' \
      || echo "WARN - ${NRE_AFTER} nre entries during steady-state")" \
      | tee -a "${LOG_DIR}/group2-timestamp.txt"
  else
    echo "kube-burner log not found in ARTIFACT_DIR" | tee "${LOG_DIR}/group2-timestamp.txt"
  fi

  # macbindings — count _uuid records (one per binding, not lines)
  {
    echo "=== Total macbindings ==="
    oc exec -n openshift-ovn-kubernetes "${POD}" -c ovn-controller -- \
      ovn-sbctl list mac 2>/dev/null | grep -c "_uuid" || echo 0
    echo "=== Macbindings per CUDN (top 10) ==="
    oc exec -n openshift-ovn-kubernetes "${POD}" -c ovn-controller -- \
      ovn-sbctl list mac 2>/dev/null \
      | grep -o 'rtoe-GR_cluster_udn_cudn\.[0-9]*_.*' \
      | sort | uniq -c | sort -rn | head -10 || true
    echo "=== Total CUDN macbindings ==="
    oc exec -n openshift-ovn-kubernetes "${POD}" -c ovn-controller -- \
      ovn-sbctl list mac 2>/dev/null | grep -c "rtoe-GR_cluster_udn_cudn" || echo 0
  } | tee "${LOG_DIR}/macbindings.txt"

  oc adm node-logs "${NODE}" -u ovs-vswitchd \
    > "${LOG_DIR}/ovs-vswitchd.log" 2>/dev/null || true

  # Stream tar from node host filesystem — avoids debug pod disappearing before copy
  oc debug node/"${NODE}" -- chroot /host bash -c \
    "tar -czf - /var/log/pods/openshift-* 2>/dev/null" \
    > "${LOG_DIR}/pods-logs.tgz" || true
fi

oc get pods -A -l "${CLIENT_APP_LABEL}" \
  --no-headers 2>/dev/null | tee "${LOG_DIR}/pod-ready-state.txt"

mkdir -p "${LOG_DIR}/client-pod-logs"
oc get pods -A -l "${CLIENT_APP_LABEL}" --no-headers 2>/dev/null \
  | awk '{print $1, $2}' \
  | while read -r NS POD_NAME; do
      oc logs -n "${NS}" "${POD_NAME}" 2>/dev/null \
        > "${LOG_DIR}/client-pod-logs/${NS}-${POD_NAME}.log" || true
    done

# Match both Scenario A (FAIL->) and Scenario B (failures)
FAIL_COUNT=$(grep -rl -e "failures" -e "FAIL->" "${LOG_DIR}/client-pod-logs/" 2>/dev/null | wc -l || echo 0)
echo "Pods with ping/connectivity failures: ${FAIL_COUNT}" | tee "${LOG_DIR}/ping-failures.txt"

# Pod ready latency from ARTIFACT_DIR (written by workload step in same pod)
{
  echo "=== Pod ready latency ==="
  KB_LOG2=$(find "${ARTIFACT_DIR}" -name "kube-burner-ocp-*.log" -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1 || true)
  if [ -n "${KB_LOG2}" ]; then
    grep -h "Ready 99th\|Ready P99\|cudn-density: Ready" "${KB_LOG2}" 2>/dev/null || echo "No latency data"
  else
    echo "kube-burner log not found in ARTIFACT_DIR"
  fi
} | tee "${LOG_DIR}/pod-ready-latency.txt"

oc adm must-gather --dest-dir="${LOG_DIR}/must-gather-net" \
  -- gather_network_logs 2>/dev/null || true

echo "Log collection complete. Artifacts in ${LOG_DIR}"
ls -lh "${LOG_DIR}/"
