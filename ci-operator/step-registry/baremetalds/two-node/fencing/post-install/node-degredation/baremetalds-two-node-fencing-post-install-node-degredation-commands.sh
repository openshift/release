#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
log() { echo "[$(date -u +'%F %T%z')] $*"; }

echo "baremetalds-two-node-fencing-post-install-node-degredation starting..."

ART_BASE="${ARTIFACT_DIR:-/tmp/artifacts}/degraded-two-node"
mkdir -p "${ART_BASE}"
KUBECONFIG="${SHARED_DIR}/kubeconfig"
export KUBECONFIG

# configurable capture window (defaults: 10 minutes, 2s interval)
CAPTURE_LOOPS="${CAPTURE_LOOPS:-300}" # 300 * 2s = 600s
CAPTURE_INTERVAL="${CAPTURE_INTERVAL:-2}"
CAPTURE_SECS="$(( CAPTURE_LOOPS * CAPTURE_INTERVAL + 10 ))"

if ! command -v oc >/dev/null 2>&1; then
  log "oc not found, installing client..."
  CLI_TAG_LOCAL="${CLI_TAG:-4.20}"
  UNAME_M="$(uname -m)"
  case "$UNAME_M" in
    x86_64) OC_TARBALL="openshift-client-linux.tar.gz" ;;
    aarch64|arm64) OC_TARBALL="openshift-client-linux-arm64.tar.gz" ;;
    *) log "Unsupported arch: $UNAME_M"; exit 1 ;;
  esac
  url="${OC_CLIENT_URL:-https://mirror.openshift.com/pub/openshift-v4/clients/ocp/candidate-${CLI_TAG_LOCAL}/${OC_TARBALL}}"
  mkdir -p /tmp/ocbin
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" | tar -xz -C /tmp/ocbin oc
  else
    wget -qO- "$url" | tar -xz -C /tmp/ocbin oc
  fi
  chmod +x /tmp/ocbin/oc || true
  export PATH="/tmp/ocbin:$PATH"
  hash -r
fi
oc version --client | tee "${ART_BASE}/oc-version.txt" || true

# -----------------------------
# capture window helpers
# -----------------------------
start_capture_window() {
  local label="${1:-during-fence}" ts out
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  out="${ART_BASE}/capture-${label}-${ts}"
  mkdir -p "$out"
  log "Starting capture window -> $out"

  # EndpointSlice watch (timestamped)  — NOTE plural: endpointslices
  (
    set +e
    timeout "${CAPTURE_SECS}s" bash -lc '
      oc -n openshift-image-registry get endpointslices -l kubernetes.io/service-name=image-registry -w |
        while IFS= read -r line; do echo "['"$(date -u +%FT%TZ)"'] $line"; done
    ' >"${out}/ep-slice-watch.log" 2>&1
  ) & echo $! >"${out}/.pid-ep-slice"

  # Endpoints watch (timestamped)
  (
    set +e
    timeout "${CAPTURE_SECS}s" bash -lc '
      oc -n openshift-image-registry get ep image-registry -w |
        while IFS= read -r line; do echo "['"$(date -u +%FT%TZ)"'] $line"; done
    ' >"${out}/ep-watch.log" 2>&1
  ) & echo $! >"${out}/.pid-ep"

  # kube-controller-manager (endpoints/node/attach-detach controllers)
  (
    set +e
    timeout "${CAPTURE_SECS}s" oc -n openshift-kube-controller-manager \
      logs -l app=kube-controller-manager --tail=-1 --all-containers -f
  ) >"${out}/kcm.log" 2>&1 &
  echo $! >"${out}/.pid-kcm"

  # CSI facts + logs (attach/detach timing)
  oc get sc >"${out}/storageclasses.txt" || true
  oc -n openshift-cluster-csi-drivers get pods -o wide >"${out}/csi-pods.txt" || true
  oc -n openshift-cluster-csi-drivers logs --tail=2000 -l app=csi-controller -c csi-attacher \
    >"${out}/csi-attacher.log" 2>&1 || true

  # Registry pod tolerations + Events (eviction + attach clues)
  oc -n openshift-image-registry get pods -l docker-registry=default -o yaml |
    sed -n '/^  tolerations:/,/^[^ ]/p' >"${out}/registry-pod-tolerations.yaml" || true
  for p in $(oc -n openshift-image-registry get pods -l docker-registry=default -o name 2>/dev/null); do
    oc -n openshift-image-registry describe "$p" | sed -n '/Events:/,$p' \
      >"${out}/describe-$(basename "$p").txt" || true
  done

  # PVC/PV
  local claim pv
  claim="$(oc get configs.imageregistry.operator.openshift.io/cluster -o jsonpath='{.spec.storage.pvc.claim}' 2>/dev/null || true)"
  [[ -z "${claim}" ]] && claim="image-registry-storage"
  oc -n openshift-image-registry get pvc "${claim}" -o yaml >"${out}/pvc-${claim}.yaml" 2>/dev/null || true
  pv="$(oc -n openshift-image-registry get pvc "${claim}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  echo "${pv:-<unbound>}" >"${out}/pv-name.txt"
  if [[ -n "${pv}" ]]; then
    oc get pv "${pv}" -o yaml >"${out}/pv-${pv}.yaml" 2>/dev/null || true
  fi

  # /v2 time-series from a Ready master (no oc inside the pod)
  local SURV
  SURV="$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | awk '$2=="True"{print $1; exit}')"
  cat >"${out}/curl-v2-watch.yaml" <<'YAML'
apiVersion: batch/v1
kind: Job
metadata: {name: curl-v2-watch, namespace: default}
spec:
  template:
    spec:
      nodeName: __SURV__
      restartPolicy: Never
      containers:
      - name: w
        image: registry.access.redhat.com/ubi9/ubi
        command: ["/bin/sh","-lc"]
        args:
        - |
          i=0
          while [ $i -lt __LOOPS__ ]; do
            ts=$(date -u +%FT%TZ)
            code=$(curl -ksS -m 3 -o /dev/null -w "%{http_code}" https://image-registry.openshift-image-registry.svc:5000/v2/ || echo ERR)
            echo "$ts code=$code"
            i=$((i+1))
            sleep __INTERVAL__
          done
YAML
  # inject placeholders
  sed -i "s/__SURV__/${SURV}/" "${out}/curl-v2-watch.yaml"
  sed -i "s/__LOOPS__/${CAPTURE_LOOPS}/" "${out}/curl-v2-watch.yaml"
  sed -i "s/__INTERVAL__/${CAPTURE_INTERVAL}/" "${out}/curl-v2-watch.yaml"
  # if SURV could not be resolved, drop nodeName
  if [[ -z "${SURV}" ]]; then sed -i '/nodeName:/d' "${out}/curl-v2-watch.yaml"; fi
  oc apply -f "${out}/curl-v2-watch.yaml" >/dev/null 2>&1 || true

  echo "$out"
}

stop_capture_window() {
  local out="$1"
  log "Stopping capture window -> $out"
  # fetch curl series and delete job
  oc -n default logs job/curl-v2-watch >"${out}/curl-v2-watch.txt" 2>&1 || true
  oc -n default delete job curl-v2-watch --ignore-not-found >/dev/null 2>&1 || true
  # kill watchers
  for pidf in "${out}"/.pid-*; do
    [[ -f "$pidf" ]] && kill "$(cat "$pidf")" 2>/dev/null || true
  done
  sleep 1 || true
}

# -----------------------------
# Triage (mostly unchanged)
# -----------------------------
triage_imageregistry() {
  local label="${1:-manual}" ts outdir route_host jobname
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  outdir="${ART_BASE}/triage-imageregistry-${label}-${ts}"
  mkdir -p "$outdir"
  echo "== Triage (image-registry vs API) -> $outdir"

  # Registry ground truth
  oc get image.config/cluster -o yaml >"${outdir}/image-config.yaml" || true
  oc get co image-registry -o yaml >"${outdir}/co-image-registry.yaml" || true
  oc -n openshift-image-registry get deploy,rs,pod,svc,ep,route -o wide >"${outdir}/imageregistry-objs.txt" 2>&1 || true

  # Route (optional)
  if oc -n openshift-image-registry get route default >/dev/null 2>&1; then
    oc -n openshift-image-registry describe route default >"${outdir}/route-default-describe.txt" 2>&1 || true
    route_host="$(oc -n openshift-image-registry get route default -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || true)"
  else
    route_host=""
    echo "No 'default' route (spec.defaultRoute false or not created)" >"${outdir}/route-default-describe.txt"
  fi

  # Deploy logs (optional)
  if oc -n openshift-image-registry get deploy image-registry >/dev/null 2>&1; then
    oc -n openshift-image-registry logs deploy/image-registry --all-containers --tail=-1 \
      >"${outdir}/imageregistry-logs.txt" 2>&1 || true
  else
    echo "Deployment image-registry not found" >"${outdir}/imageregistry-logs.txt"
  fi

  # One-shot dataplane probe
  jobname="curl-registry-$(date -u +%H%M%S)"
  cat >"${outdir}/curl-job.yaml" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${jobname}
  namespace: default
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: curl
        image: registry.access.redhat.com/ubi9/ubi
        env: [{name: ROUTE_HOST, value: "${route_host}"}]
        command: ["/bin/sh","-lc"]
        args:
        - |
          set -e
          echo "TIME=\$(date -u +%FT%TZ) POD->SVC"
          curl -k -sS -o /dev/null -w "%{http_code}\n" https://image-registry.openshift-image-registry.svc:5000/v2/ || true
          echo "TIME=\$(date -u +%FT%TZ) POD->ROUTE (\$ROUTE_HOST)"
          if [ -n "\$ROUTE_HOST" ]; then
            curl -k -sS -o /dev/null -w "%{http_code}\n" "https://\$ROUTE_HOST/v2/" || true
          else
            echo "no-route"
          fi
YAML
  oc apply -f "${outdir}/curl-job.yaml" >/dev/null 2>&1 || true
  oc -n default wait --for=condition=complete "job/${jobname}" --timeout=180s >/dev/null 2>&1 || true
  oc -n default logs "job/${jobname}" >"${outdir}/curl-probe.txt" 2>&1 || true
  oc -n default delete job "${jobname}" --ignore-not-found >/dev/null 2>&1 || true

  # KAS basics
  oc get co kube-apiserver -o yaml >"${outdir}/co-kas.yaml" || true
  oc -n openshift-kube-apiserver get pods -o wide >"${outdir}/kas-pods.txt" || true
  oc -n openshift-kube-apiserver get pod \
    -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,PHASE:.status.phase,READY:.status.containerStatuses[*].ready \
    >"${outdir}/kas-restarts.txt" 2>/dev/null || true
  oc -n openshift-kube-apiserver get pods -o name >"${outdir}/kas-pod-names.txt" || true
  while read -r p; do
    [[ -z "$p" ]] && continue
    oc -n openshift-kube-apiserver logs "$p" --all-containers --tail=300 >"${outdir}/kas-logs-$(basename "$p").txt" 2>&1 || true
  done <"${outdir}/kas-pod-names.txt"

  # /readyz burst
  for i in {1..10}; do
    echo "TIME=$(date -u +%FT%TZ)"
    oc get --raw /readyz?verbose || true
    sleep 2
  done >"${outdir}/kas-readyz-burst.txt" 2>&1

  # Kubernetes endpoints
  oc -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o yaml >"${outdir}/kubernetes-endpointslice.yaml" 2>&1 || true
  oc -n default get endpoints kubernetes -o yaml >"${outdir}/kubernetes-endpoints.yaml" 2>&1 || true

  # OCM logs
  oc get co openshift-controller-manager -o yaml >"${outdir}/co-ocm.yaml" || true
  oc -n openshift-controller-manager get pods -o wide >="${outdir}/ocm-pods.txt" || true
  oc -n openshift-controller-manager logs -l app=openshift-controller-manager --tail=800 --all-containers >"${outdir}/ocm-logs-tail.txt" 2>&1 || true

  # KAS operator + versions
  oc get kubeapiserver.operator.openshift.io/cluster -o yaml >"${outdir}/kas-operator.yaml" || true
  oc -n openshift-kube-apiserver get cm,secret -l openshift.io/revision -o name | sort -V >"${outdir}/kas-revisioned-names.txt" 2>/dev/null || true
  oc get clusterversion version -o yaml >"${outdir}/clusterversion.yaml" || true

  # quick greps
  grep -E -ni 'timeout|deadline|connection reset|i/o timeout|context deadline|transport is closing' \
    "${outdir}"/kas-logs-*.txt "${outdir}/ocm-logs-tail.txt" "${outdir}/imageregistry-logs.txt" \
    >"${outdir}/timeouts-grep.txt" 2>/dev/null || true
}

snapshot_cluster() {
  local label="$1" ts outdir
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  outdir="${ART_BASE}/${label}-${ts}"
  mkdir -p "${outdir}"
  echo "== Snapshot (${label}) -> ${outdir}"
  oc get configs.imageregistry.operator.openshift.io/cluster -o yaml >"${outdir}/imageregistry-config.yaml" || true
  oc get co image-registry -o yaml | sed -n '/^  conditions:/,$p' >"${outdir}/image-registry-co-conditions.yaml" || true
  oc get jobs -n openshift-etcd >"${outdir}/openshift-etcd-jobs.txt" || true
  oc get co -o wide >"${outdir}/clusteroperators-wide.txt" || true
  oc get co etcd -o wide >"${outdir}/co-etcd-wide.txt" || true
  oc get co etcd -o yaml >"${outdir}/co-etcd.yaml" || true
  oc -n openshift-etcd get events --sort-by=.lastTimestamp >"${outdir}/events-openshift-etcd.txt" || true
  oc -n openshift-etcd-operator get events --sort-by=.lastTimestamp >"${outdir}/events-openshift-etcd-operator.txt" || true
}

# -------- Main flow --------
if [[ -z "${DEGRADED_NODE:-}" ]]; then
  echo "DEGRADED_NODE is not set, skipping node degradation"
  exit 0
fi
if [[ "${DEGRADED_NODE}" != "true" ]]; then
  echo "DEGRADED_NODE is set to '${DEGRADED_NODE}', but not 'true', skipping node degradation"
  exit 0
fi
if [[ ! -e "${SHARED_DIR}/server-ip" ]]; then
  echo "No server IP found; skipping log gathering."
  exit 0
fi

# Fetch packet conf
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

triage_imageregistry "pre-tests"
snapshot_cluster "before-degradation"

# Start capture BEFORE fencing
CAP_DIR="$(start_capture_window "during-fence")"

# Reaper to kill watchers after the window
(
  sleep "${CAPTURE_SECS}"
  for pf in "${CAP_DIR}"/.pid-*; do
    [ -f "$pf" ] && kill "$(cat "$pf")" 2>/dev/null || true
  done
) >/dev/null 2>&1 &

echo "Connecting to packet system to degrade ostest_master_1..."
timeout -s 9 5m ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<"EOF" |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -xeo pipefail
set -o nounset
set -o errexit
set -o pipefail

echo "Connected to packet system, listing VMs..."
virsh -c qemu:///system list --all

echo "Looking for ostest_master_1 node..."
if virsh -c qemu:///system domstate ostest_master_1 >/dev/null 2>&1; then
  echo "Shutting down ostest_master_1..."
  virsh -c qemu:///system shutdown ostest_master_1 || true

  echo "Getting DHCP leases to find ostest_master_0 IP..."
  virsh -c qemu:///system net-dhcp-leases ostestbm
  MASTER0_IP=$(virsh -c qemu:///system net-dhcp-leases ostestbm | grep master-0 | awk '{print $5}' | cut -d'/' -f1)
  if [[ -z "${MASTER0_IP}" ]]; then
    echo "ERROR: Could not find ostest_master_0 IP address in DHCP leases"; exit 1
  fi

  echo "Connecting to ostest_master_0 to run pcs commands..."
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 core@"${MASTER0_IP}" << 'MASTER0_EOF'
    echo "Running: sudo pcs resource status";            sudo pcs resource status
    echo "Running: sudo pcs property set stonith-enabled=false"; sudo pcs property set stonith-enabled=false
    echo "Running: sudo pcs resource cleanup etcd";      sudo pcs resource cleanup etcd
    echo "Running: sudo pcs resource status (final)";    sudo pcs resource status
MASTER0_EOF

else
  echo "WARNING: ostest_master_1 not found or not accessible"
  virsh -c qemu:///system list --all
  exit 1
fi

echo "Current VM status after node degradation:"
virsh -c qemu:///system list --all
EOF

snapshot_cluster "after-degradation"
triage_imageregistry "post-degrade"

# Stop capture and collect
stop_capture_window "$CAP_DIR"

log "Node degradation and capture completed. Artifacts:"
log " - triage pre/post dirs under: ${ART_BASE}"
log " - capture window dir: ${CAP_DIR}"
