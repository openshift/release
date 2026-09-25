#!/bin/bash
# Deploy the probe, generate TLS traffic, and retain native JSONL and logs.
# TLS policy evaluation belongs to downstream consumers, not this smoke test.
set -o nounset
set -o errexit
set -o pipefail

# ── constants ─────────────────────────────────────────────────────────────────
readonly NS="${PROBE_NAMESPACE:-tls-probe}"
readonly PROBE_IMG="${PROBE_IMAGE:?PROBE_IMAGE must be supplied by ci-operator from the stolostron/tls-probe source build}"
readonly CAPTURE_SECS="${PROBE_CAPTURE_DURATION:-180}"
readonly ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
readonly PROBE_DIR="${ARTIFACT_DIR}/tls-probe"
readonly CAPTURES_DIR="${PROBE_DIR}/captures"
readonly SCC_NAME="tls-probe-capture-${NS}"  # cluster-scoped; suffix with NS so concurrent runs on a shared/long-lived cluster don't race on the same SCC
readonly TRAFFIC_JOB_NAME="tls-probe-client-traffic"
readonly TRAFFIC_JOB_TIMEOUT="60s"
readonly CAPTURE_SELECTOR="app.kubernetes.io/name=tls-probe,app.kubernetes.io/component=capture"

# Only "${NS}" and "${NS}-"-prefixed names are accepted: create_namespace and
# cleanup pass this straight to `oc delete namespace`, so a typo or an
# unrelated protected namespace name must never reach that command.
[[ "${NS}" == "tls-probe" || "${NS}" == tls-probe-* ]] \
  || { echo "ERROR: PROBE_NAMESPACE must be 'tls-probe' or start with 'tls-probe-' (got: ${NS})" >&2; exit 1; }

# ── helpers ───────────────────────────────────────────────────────────────────
# Prefixed status line for step logs.
log() { echo "=== tls-probe: $* ==="; }
# Print an error to stderr and exit non-zero.
die() { echo "ERROR: $*" >&2; exit 1; }

# ── setup ─────────────────────────────────────────────────────────────────────
# Source the CI proxy config (if present) and create artifact directories.
setup() {
  if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
  fi
  mkdir -p "${CAPTURES_DIR}" "${PROBE_DIR}"
}

# ── cleanup ───────────────────────────────────────────────────────────────────
# Collect before deleting pods, including when capture fails.
cleanup() {
  local status=$?
  trap - EXIT
  set +e
  collect_jsonl || { if (( status == 0 )); then status=1; fi; }
  log "cleanup"
  oc delete namespace "${NS}" --ignore-not-found --wait=false || true
  oc delete scc "${SCC_NAME}" --ignore-not-found || true
  exit "${status}"
}

# ── 1. namespace + service account + scoped SCC ─────────────────────────────
# Creates an isolated namespace/SA and grants only the capabilities the eBPF
# capture needs, instead of the cluster-wide `privileged` SCC.
create_namespace() {
  log "creating namespace ${NS}"
  oc delete namespace "${NS}" --ignore-not-found --wait=true --timeout=120s || true

  oc create -f - <<EOF
# hostNetwork/hostPID require the "privileged" pod-security level; the SCC
# granted below still drops all capabilities except the ones the capture
# needs (no privileged: true, no privileged SCC).
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    security.openshift.io/disable-securitycontextconstraints: "true"
    security.openshift.io/scc.podSecurityLabelSync: "false"
  annotations:
    workload.openshift.io/allowed: management
---
# Identity the DaemonSet pods run as; the scoped SCC below targets this SA.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tls-probe
  namespace: ${NS}
EOF

  # Least-privilege SCC: hostNetwork/hostPID/hostPath for node-wide capture
  # and process attribution, plus only the capabilities eBPF TC attach and
  # perf event access require. No privileged: true, no "privileged" SCC.
  oc apply -f - <<EOF
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: ${SCC_NAME}
allowHostDirVolumePlugin: true
allowHostIPC: false
allowHostNetwork: true
allowHostPID: true
allowHostPorts: false
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
allowedCapabilities:
- BPF
- PERFMON
- NET_ADMIN
- SYS_RESOURCE
defaultAddCapabilities: null
fsGroup:
  type: RunAsAny
readOnlyRootFilesystem: false
requiredDropCapabilities:
- ALL
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: RunAsAny
seccompProfiles:
- runtime/default
supplementalGroups:
  type: RunAsAny
users:
- system:serviceaccount:${NS}:tls-probe
EOF
  sleep 10  # SCC propagation — binding is async; skip and pods will be rejected
}

# ── 2. DaemonSet ──────────────────────────────────────────────────────────────
# One pod per node; captures TLS handshakes on all interfaces for CAPTURE_SECS
# then exits cleanly (--duration). hostNetwork+hostPID give the eBPF program
# visibility into all node traffic and process attribution. Excludes arbiter
# nodes (TNA) and only tolerates the control-plane/infra taints it needs, so
# it does not spread onto resource-constrained arbiter nodes via a wildcard.
deploy_daemonset() {
  log "deploying DaemonSet (image: ${PROBE_IMG})"

  oc create -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: tls-probe
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: tls-probe
    app.kubernetes.io/component: capture
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: tls-probe
  template:
    metadata:
      labels:
        app.kubernetes.io/name: tls-probe
        app.kubernetes.io/component: capture
    spec:
      serviceAccountName: tls-probe
      hostNetwork: true   # see all node-level traffic, not just pod overlay
      hostPID: true       # process attribution via /proc
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/arbiter
                operator: DoesNotExist
      tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        operator: Exists
        effect: NoSchedule
      containers:
      - name: capture
        image: ${PROBE_IMG}
        args:
        - capture
        - --ebpf
        - /usr/local/lib/tls-probe-ebpf
        - --interface
        - all             # attach TC classifier to every network interface
        - --duration
        - "${CAPTURE_SECS}"
        - --cgroup-root
        - /host/sys/fs/cgroup  # host cgroup tree for container/pod attribution
        - --no-self-test       # suppress startup canary handshake from results
        securityContext:
          privileged: false
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
            add:
            - BPF        # load/attach eBPF programs and maps
            - PERFMON    # perf_event_open for eBPF tracing
            - NET_ADMIN  # attach TC classifier to host interfaces
            - SYS_RESOURCE  # raise RLIMIT_MEMLOCK for eBPF map allocation
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
        volumeMounts:
        - name: sys-kernel-debug
          mountPath: /sys/kernel/debug  # eBPF map inspection via debugfs
          readOnly: true
        - name: sys-fs-bpf
          mountPath: /sys/fs/bpf        # pinned eBPF maps survive probe restarts
        - name: host-cgroup
          mountPath: /host/sys/fs/cgroup  # host cgroup v2 for pod/container identity
          readOnly: true
      volumes:
      - name: sys-kernel-debug
        hostPath:
          path: /sys/kernel/debug
      - name: sys-fs-bpf
        hostPath:
          path: /sys/fs/bpf
      - name: host-cgroup
        hostPath:
          path: /sys/fs/cgroup
EOF

  oc rollout status daemonset/tls-probe -n "${NS}" --timeout=5m || {
    oc describe daemonset/tls-probe -n "${NS}" || true
    # Sanitized: no .message/.source (can carry node names/IPs), aggregate only.
    oc get events -n "${NS}" --sort-by='.lastTimestamp' \
      -o custom-columns=LAST-SEEN:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT-KIND:.involvedObject.kind,COUNT:.count \
      | tail -20 || true
    die "DaemonSet failed to roll out — probe image may not be pullable"
  }
  log "DaemonSet ready on $(oc get pods -n "${NS}" -l "${CAPTURE_SELECTOR}" --no-headers | wc -l) node(s)"
}

# ── 3. client traffic ────────────────────────────────────────────────────────
generate_traffic() {
  log "generating client TLS traffic"
  oc delete job "${TRAFFIC_JOB_NAME}" -n "${NS}" --ignore-not-found

  oc create -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${TRAFFIC_JOB_NAME}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: tls-probe
    app.kubernetes.io/component: traffic-gen
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: tls-probe
        app.kubernetes.io/component: traffic-gen
    spec:
      restartPolicy: Never
      containers:
      - name: traffic-gen
        image: ${PROBE_TRAFFIC_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -uo pipefail
          probe() { curl -sk --max-time 5 "\$1" -o /dev/null && echo "\$1 [ok]" || echo "\$1 [fail]"; }

          probe https://kubernetes.default.svc:443/healthz
          probe https://kubernetes.default.svc:443/version
          probe https://openshift.default.svc:443/.well-known/oauth-authorization-server
          probe https://image-registry.openshift-image-registry.svc:5000/healthz
          probe https://prometheus-k8s.openshift-monitoring.svc:9091/-/healthy
          probe https://alertmanager-main.openshift-monitoring.svc:9094/-/healthy
          probe https://registry.redhat.io/v2/
          probe https://quay.io/v2/
          probe https://registry.access.redhat.com/v2/
          probe https://cdn.redhat.com/

          for _ in \$(seq 1 10); do
            curl -sk --max-time 5 https://kubernetes.default.svc:443/healthz -o /dev/null &
          done
          wait
EOF

  oc wait --for=condition=complete "job/${TRAFFIC_JOB_NAME}" -n "${NS}" --timeout="${TRAFFIC_JOB_TIMEOUT}" \
    || log "traffic Job did not complete within ${TRAFFIC_JOB_TIMEOUT} (continuing with capture anyway)"
}

# ── 4. capture window ─────────────────────────────────────────────────────────
# The capture container's restartPolicy is the DaemonSet-mandated "Always", so
# the container restarts (not "Succeeds") once `--duration` elapses and the
# pod never reaches phase Succeeded. Poll each pod's last-terminated exit code
# instead of just restartCount: exitCode==0 means the capture finished
# cleanly; any non-zero exit fails the step immediately instead of silently
# collecting partial/garbage logs. Timing out (no pod finishing in time) also
# fails the step; cleanup still collects any available logs.
wait_for_capture() {
  log "waiting for ${CAPTURE_SECS}s capture to complete (detected via container exit)"
  local deadline=$(( $(date +%s) + CAPTURE_SECS + 60 ))
  local expected
  expected=$(oc get daemonset/tls-probe -n "${NS}" -o jsonpath='{.status.desiredNumberScheduled}')
  [[ "${expected}" =~ ^[1-9][0-9]*$ ]] \
    || die "DaemonSet reported invalid desired pod count: ${expected:-empty}"

  while (( $(date +%s) < deadline )); do
    local pods_json bad completed
    pods_json=$(oc get pods -n "${NS}" -l "${CAPTURE_SELECTOR}" -o json)

    bad=$(jq -r '
      [.items[].status.containerStatuses[]?
       | select(.name == "capture")
       | .lastState.terminated?
       | select(.exitCode != 0)
       | .exitCode]
      | unique
      | join(",")
    ' <<< "${pods_json}")
    [[ -n "${bad}" ]] && die "capture container(s) exited non-zero: ${bad}"

    completed=$(jq '
      [.items[]
       | select(any(.status.containerStatuses[]?;
           .name == "capture" and .lastState.terminated.exitCode == 0))]
      | length
    ' <<< "${pods_json}")
    [[ "${completed}" -eq "${expected}" ]] && return 0
    sleep 5
  done

  die "capture window (${CAPTURE_SECS}s) elapsed without every pod completing a capture cycle"
}

# ── 5. collect JSONL ──────────────────────────────────────────────────────────
# Preserve the complete container log and extract JSON lines without rewriting
# events or selecting TLS versions, ports, or handshake types.
collect_jsonl() {
  log "collecting JSONL and logs from DaemonSet pods"
  local pods pod raw out pod_count=0 total_events=0 failed=0
  pods=$(oc get pods -n "${NS}" -l "${CAPTURE_SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || return 1

  for pod in ${pods}; do
    raw="${CAPTURES_DIR}/capture-${pod_count}.log"
    out="${CAPTURES_DIR}/capture-${pod_count}.jsonl"
    log "${pod} -> capture-${pod_count}"
    if ! oc logs "${pod}" -n "${NS}" -c capture --previous > "${raw}"; then
      log "${pod}: completed capture unavailable; retaining current logs separately"
      failed=1
      oc logs "${pod}" -n "${NS}" -c capture > "${CAPTURES_DIR}/capture-${pod_count}.current.log" || true
    fi
    # grep returns 1 for an empty capture, checked across all pods below.
    grep -E '^\{' "${raw}" > "${out}" || { [[ $? -eq 1 ]] || failed=1; }
    total_events=$(( total_events + $(wc -l < "${out}") ))
    pod_count=$(( pod_count + 1 ))
  done

  log "collected from ${pod_count} pod(s) — ${total_events} events in ${CAPTURES_DIR}"
  if (( total_events == 0 )); then
    log "ERROR: no probe events captured"
    failed=1
  fi
  return "${failed}"
}

# ── main ──────────────────────────────────────────────────────────────────────
# Collection and cleanup run on exit, including on operational failure.
main() {
  setup
  trap cleanup EXIT

  create_namespace
  deploy_daemonset
  generate_traffic
  wait_for_capture
}

main "$@"
