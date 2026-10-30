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

  # --- nre (long poll intervals) ---
  echo "Collecting nre entries..."
  {
    echo "=== ovn-controller nre ==="
    oc logs -n openshift-ovn-kubernetes "${POD}" -c ovn-controller 2>/dev/null | grep nre
    echo "=== sbdb nre ==="
    oc logs -n openshift-ovn-kubernetes "${POD}" -c sbdb 2>/dev/null | grep nre
  } | tee "${LOG_DIR}/nre-poll-intervals.txt"

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

  # --- SOS report ---
  echo "Collecting sos report (this takes ~20 min)..."
  SOS_POD=$(oc debug node/"${NODE}" --to-namespace=default -- bash -c "
    sos report \
      -e openshift -e openshift_ovn -e openvswitch -e podman -e crio \
      -k crio.all=on -k crio.logs=on \
      -k podman.all=on -k podman.logs=on \
      -k networking.ethtool-namespaces=off \
      --all-logs --plugin-timeout=1200 --batch 2>&1 | grep 'tar.xz' | awk '{print \$NF}'
  " 2>/dev/null || true)

  DEBUG_POD=$(oc get pods -n default --no-headers | grep "${NODE//./-}" | grep debug | awk '{print $1}' | head -1)
  if [ -n "${DEBUG_POD}" ]; then
    oc cp "default/${DEBUG_POD}:/host/var/tmp/$(basename ${SOS_POD})" \
      "${LOG_DIR}/sosreport.tar.xz" 2>/dev/null || \
    oc cp "default/${DEBUG_POD}:/var/tmp/$(basename ${SOS_POD})" \
      "${LOG_DIR}/sosreport.tar.xz" 2>/dev/null || true
  fi

  # --- All openshift pod logs from node ---
  echo "Collecting openshift pod logs from node..."
  oc debug node/"${NODE}" -- bash -c "
    chroot /host
    tar -czf /var/tmp/pods-logs.\$(hostname).tgz /var/log/pods/openshift-* 2>/dev/null
  " || true
  DEBUG_POD2=$(oc get pods -n default --no-headers | grep "${NODE//./-}" | grep debug | awk '{print $1}' | head -1)
  if [ -n "${DEBUG_POD2}" ]; then
    oc cp "default/${DEBUG_POD2}:/host/var/tmp/pods-logs.${NODE}.tgz" \
      "${LOG_DIR}/pods-logs.tgz" 2>/dev/null || true
  fi
fi

# --- Pod ready state ---
echo "=== Pod ready state ===" | tee "${LOG_DIR}/pod-ready-state.txt"
oc get pods -A -l "${CLIENT_APP_LABEL}" \
  --no-headers 2>/dev/null | tee -a "${LOG_DIR}/pod-ready-state.txt"

# --- Client pod logs (for ping failures) ---
echo "Collecting client pod logs..."
mkdir -p "${LOG_DIR}/client-pod-logs"
oc get pods -A -l "${CLIENT_APP_LABEL}" --no-headers 2>/dev/null \
  | awk '{print $1, $2}' \
  | while read NS POD_NAME; do
      oc logs -n "${NS}" "${POD_NAME}" 2>/dev/null \
        > "${LOG_DIR}/client-pod-logs/${NS}-${POD_NAME}.log" || true
    done

# Ping failure summary
echo "=== Ping failure summary ===" | tee "${LOG_DIR}/ping-failures.txt"
grep -l "failures" "${LOG_DIR}/client-pod-logs/"*.log 2>/dev/null \
  | wc -l | tee -a "${LOG_DIR}/ping-failures.txt" || true

# --- kube-burner log: pod ready latency ---
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
