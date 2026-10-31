#!/bin/bash
set -o nounset
set -o pipefail
set -x

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  set +x
  source "${SHARED_DIR}/proxy-conf.sh"
  set -x
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}/midterm-logs"
LOG_DIR="${ARTIFACT_DIR}/midterm-logs"

# Find node where client pods are hosted
NODE=$(oc get pods -A --no-headers \
  -o custom-columns=:.metadata.namespace,:.metadata.name,:.spec.nodeName \
  2>/dev/null | grep "cudn-density" | grep "client-1-" | awk '{print $3}' | sort | uniq | head -1)

if [ -z "$NODE" ]; then
  echo "No client pods found — skipping node-specific log collection"
else
  echo "Client pods on node: $NODE"
  POD=$(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node \
    --field-selector spec.nodeName="${NODE}" \
    -o jsonpath='{.items[0].metadata.name}')
  echo "ovnkube-node pod: $POD"

  # --- NBDB and SBDB files ---
  echo "Collecting NBDB/SBDB..."
  oc exec -n openshift-ovn-kubernetes "${POD}" -c nbdb -- \
    cat /etc/ovn/ovnnb_db.db > "${LOG_DIR}/ovnnb_db.db" 2>/dev/null || true
  oc exec -n openshift-ovn-kubernetes "${POD}" -c sbdb -- \
    cat /etc/ovn/ovnsb_db.db > "${LOG_DIR}/ovnsb_db.db" 2>/dev/null || true

  # --- Full nre logs ---
  echo "Collecting nre entries..."
  {
    echo "=== ovn-controller nre (all) ==="
    oc logs -n openshift-ovn-kubernetes "${POD}" -c ovn-controller 2>/dev/null | grep nre || true
    echo ""
    echo "=== sbdb nre (all) ==="
    oc logs -n openshift-ovn-kubernetes "${POD}" -c sbdb 2>/dev/null | grep nre || true
  } | tee "${LOG_DIR}/nre-all.txt"

  # --- nre after Group 2 start (key metric: fix validation) ---
  KB_LOG=$(find /tmp -name "kube-burner-ocp-*.log" 2>/dev/null | head -1)
  if [ -n "$KB_LOG" ]; then
    GROUP2_LINE=$(grep "Group 2: Creating object replicas from iteration" "$KB_LOG" | head -1)
    GROUP2_TS=$(echo "$GROUP2_LINE" | awk '{print $1"T"$2}' | tr -d '"')
    echo "Group 2 started at: $GROUP2_TS" | tee "${LOG_DIR}/group2-timestamp.txt"

    {
      echo "=== nre AFTER Group 2 start (steady-state — fix validation) ==="
      echo "Group 2 start timestamp: $GROUP2_TS"
      echo ""
      echo "--- ovn-controller nre after Group 2 ---"
      oc logs -n openshift-ovn-kubernetes "${POD}" -c ovn-controller 2>/dev/null \
        | grep nre | awk -v ts="$GROUP2_TS" '$1 >= ts' || true
      echo ""
      echo "--- sbdb nre after Group 2 ---"
      oc logs -n openshift-ovn-kubernetes "${POD}" -c sbdb 2>/dev/null \
        | grep nre | awk -v ts="$GROUP2_TS" '$1 >= ts' || true
    } | tee "${LOG_DIR}/nre-after-group2.txt"

    NRE_AFTER=$(grep -c "Unreasonably long" "${LOG_DIR}/nre-after-group2.txt" || echo 0)
    echo "nre count after Group 2 (steady-state): $NRE_AFTER" | tee -a "${LOG_DIR}/group2-timestamp.txt"
    echo "RESULT: $([ "$NRE_AFTER" -eq 0 ] && echo 'PASS - no nre during steady-state ping' || echo "WARN - $NRE_AFTER nre entries during steady-state")" \
      | tee -a "${LOG_DIR}/group2-timestamp.txt"
  fi

  # --- macbindings ---
  echo "Collecting macbindings..."
  {
    echo "=== Total macbindings ==="
    oc exec -n openshift-ovn-kubernetes "${POD}" -c ovn-controller -- \
      ovn-sbctl list mac 2>/dev/null | wc -l
    echo "=== Macbindings per CUDN (top 10) ==="
    oc exec -n openshift-ovn-kubernetes "${POD}" -c ovn-controller -- \
      ovn-sbctl list mac 2>/dev/null \
      | grep -o 'rtoe-GR_cluster_udn_cudn\.[0-9]*_.*' \
      | sort | uniq -c | sort -rn | head -10
    echo "=== Total CUDN macbindings ==="
    oc exec -n openshift-ovn-kubernetes "${POD}" -c ovn-controller -- \
      ovn-sbctl list mac 2>/dev/null | grep "rtoe-GR_cluster_udn_cudn" | wc -l
  } | tee "${LOG_DIR}/macbindings.txt"

  # --- OVS logs ---
  echo "Collecting OVS logs..."
  oc adm node-logs "${NODE}" -u ovs-vswitchd \
    > "${LOG_DIR}/ovs-vswitchd.log" 2>/dev/null || true
fi

# --- Pod ready state ---
echo "=== Pod ready state ===" | tee "${LOG_DIR}/pod-ready-state.txt"
oc get pods -A -l "${CLIENT_APP_LABEL}" \
  --no-headers 2>/dev/null | tee -a "${LOG_DIR}/pod-ready-state.txt"

# --- Client pod logs ---
echo "Collecting client pod logs..."
mkdir -p "${LOG_DIR}/client-pod-logs"
oc get pods -A -l "${CLIENT_APP_LABEL}" --no-headers 2>/dev/null \
  | awk '{print $1, $2}' \
  | while read NS POD_NAME; do
      oc logs -n "${NS}" "${POD_NAME}" 2>/dev/null \
        > "${LOG_DIR}/client-pod-logs/${NS}-${POD_NAME}.log" || true
    done

# Ping failure summary
FAIL_COUNT=$(grep -rl "failures" "${LOG_DIR}/client-pod-logs/" 2>/dev/null | wc -l || echo 0)
echo "Pods with ping failures: $FAIL_COUNT" | tee "${LOG_DIR}/ping-failures.txt"

# --- Pod ready latency from kube-burner log ---
echo "=== Pod ready latency ===" | tee "${LOG_DIR}/pod-ready-latency.txt"
find /tmp -name "kube-burner-ocp-*.log" 2>/dev/null \
  | xargs grep -h "Ready 99th\|Ready P99\|cudn-density: Ready" 2>/dev/null \
  | tee -a "${LOG_DIR}/pod-ready-latency.txt" || true

# --- Must-gather network logs ---
echo "Collecting must-gather network logs..."
oc adm must-gather --dest-dir="${LOG_DIR}/must-gather-net" \
  -- gather_network_logs 2>/dev/null || true

echo "Log collection complete. Artifacts in ${LOG_DIR}"
ls -lh "${LOG_DIR}/"
