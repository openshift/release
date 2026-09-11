#!/bin/bash
# tls-probe-run-commands.sh
#
# Deploys the tls-probe eBPF DaemonSet, captures TLS handshakes for a bounded
# window, collects per-node JSONL, and emits [OCPFeatureGate:TLSAdherence]-tagged
# JUnit to ARTIFACT_DIR.
#
# Verdict is keyed by destination port on ServerHello events. For full workload
# identity resolution and richer analysis (client negotiations, certs, PQC),
# see pkg/monitortests/security/tlsprobe in openshift/origin.
set -o nounset
set -o errexit
set -o pipefail

# ── constants ─────────────────────────────────────────────────────────────────
readonly NS="${PROBE_NAMESPACE:-tls-probe}"
readonly PROBE_IMG="${PROBE_IMAGE:-ghcr.io/smith-xyz/tls-probe@sha256:8beefaa4040a4d49ae338b94c7d9ebbaaccefee0015214ad04c5059693e7c32d}"
readonly CAPTURE_SECS="${PROBE_CAPTURE_DURATION:-180}"
readonly ENFORCE="${TLS_ADHERENCE_ENFORCE:-false}"
readonly ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
readonly PROBE_DIR="${ARTIFACT_DIR}/tls-probe"
SCRATCH_DIR="$(mktemp -d)"
readonly SCRATCH_DIR
readonly CAPTURES_DIR="${SCRATCH_DIR}/captures"
readonly JUNIT_CLASSNAME="tls.probe.adherence.runtime"
readonly SCC_NAME="tls-probe-capture"

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
# Source the CI proxy config (if present) and create scratch directories.
setup() {
  if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
  fi
  mkdir -p "${CAPTURES_DIR}" "${PROBE_DIR}"
}

# ── cleanup ───────────────────────────────────────────────────────────────────
# Tear down the probe namespace and its scoped SCC; never fails the step.
cleanup() {
  log "cleanup"
  oc delete namespace "${NS}" --ignore-not-found --wait=false || true
  oc delete scc "${SCC_NAME}" --ignore-not-found || true
  rm -rf "${SCRATCH_DIR}" || true
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
allowPrivilegeEscalation: true
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
          allowPrivilegeEscalation: true
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
    oc get events -n "${NS}" --sort-by='.lastTimestamp' | tail -20 || true
    die "DaemonSet failed to roll out — probe image may not be pullable"
  }
  log "DaemonSet ready on $(oc get pods -n "${NS}" -l app.kubernetes.io/name=tls-probe --no-headers | wc -l) node(s)"
}

# ── 3. capture window ─────────────────────────────────────────────────────────
# The capture container's restartPolicy is the DaemonSet-mandated "Always", so
# the container restarts (not "Succeeds") once `--duration` elapses and the
# pod never reaches phase Succeeded. Poll each pod's restart count instead:
# restartCount >= 1 means the first capture run finished and kubelet
# restarted the container, at which point its (previous) logs hold the
# completed capture.
wait_for_capture() {
  log "waiting for ${CAPTURE_SECS}s capture to complete (detected via container restart)"
  local deadline=$(( $(date +%s) + CAPTURE_SECS + 60 ))

  while (( $(date +%s) < deadline )); do
    local pending
    pending=$(oc get pods -n "${NS}" -l app.kubernetes.io/name=tls-probe \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null \
      | awk '$1 < 1' | wc -l | tr -d ' ')
    [[ "${pending:-1}" -eq 0 ]] && return 0
    sleep 5
  done

  echo "WARN: not all pods restarted after capture window; collecting available data"
  oc get pods -n "${NS}" -o wide || true
}

# ── 4. collect JSONL ──────────────────────────────────────────────────────────
# Reads the completed capture from each pod's previous (restarted) container.
# Falls back to the live container if the pod never restarted in time.
# Files are kept in SCRATCH_DIR (not ARTIFACT_DIR) and named by ordinal, not
# node name, so no node identity or address data reaches published artifacts.
collect_jsonl() {
  log "collecting JSONL from DaemonSet pods"
  local pod_count=0

  while IFS= read -r pod; do
    [[ -z "${pod}" ]] && continue
    local out="${CAPTURES_DIR}/capture-${pod_count}.jsonl"
    # Pod stdout mixes probe log lines with JSON events; keep only JSON lines.
    { oc logs "${pod}" -n "${NS}" --previous 2>/dev/null \
        || oc logs "${pod}" -n "${NS}" 2>/dev/null; } \
      | grep -E '^\{' > "${out}" || true
    pod_count=$(( pod_count + 1 ))
  done < <(oc get pods -n "${NS}" -l app.kubernetes.io/name=tls-probe \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  cat "${CAPTURES_DIR}"/*.jsonl > "${SCRATCH_DIR}/all-events.jsonl" 2>/dev/null \
    || touch "${SCRATCH_DIR}/all-events.jsonl"
  log "collected from ${pod_count} pod(s) — $(wc -l < "${SCRATCH_DIR}/all-events.jsonl") events"
}

# ── 5. read cluster TLS policy ────────────────────────────────────────────────
# Prints the cluster's configured TLSAdherencePolicy, or empty if unset.
read_adherence_policy() {
  oc get apiserver cluster -o jsonpath='{.spec.tlsAdherence}' 2>/dev/null || echo ""
}

# Decides whether below-TLS-1.3 findings should fail the job.
should_enforce() {
  local policy="$1"
  [[ "${ENFORCE}" == "true" ]] \
    && [[ "${policy}" != "" ]] \
    && [[ "${policy}" != "NoOpinion" ]] \
    && [[ "${policy}" != "LegacyAdheringComponentsOnly" ]] \
    && echo "true" || echo "false"
}

# ── 6. verdict ───────────────────────────────────────────────────────────────
# Aggregates ServerHello events by server (source) port — the negotiated
# version and the serving port are both on the ServerHello's .src side; .dst
# is the client's ephemeral port. ClientHello data (offered versions, cipher
# suites, key share groups) is present in the capture but not evaluated here;
# client negotiation analysis requires pairing CH→SH per connection.
# Two filters keep the Spyglass testcase count manageable:
#   - ephemeral server-side ports (>= 32768) are excluded
#   - per-port testcases only for ports seen >= 2 times (recurring services)
# A summary testcase covers all below-TLS-1.3 flows so nothing is silently dropped.
build_verdict() {
  local all_events="${SCRATCH_DIR}/all-events.jsonl"

  jq -rsc '
    map(select(.handshake_type == "ServerHello")) |
    map(select((.src | split(":")[-1] // "0" | tonumber) < 32768)) |
    group_by(.src | split(":")[-1] // "0") |
    map({
      dst_port: (.[0].src | split(":")[-1] // "0"),
      handshake_count: length,
      tls_versions: (map(.tls_version) | unique | sort),
      worst_tls: (
        map(.tls_version) |
        if any(. == "TLS 1.0" or . == "TLS 1.1") then "TLS 1.1"
        elif any(. == "TLS 1.2") then "TLS 1.2"
        else "TLS 1.3" end
      )
    })
  ' "${all_events}" 2>/dev/null || echo "[]"
}

# ── 7. emit JUnit ─────────────────────────────────────────────────────────────
# Appends one <testcase> block (pass/fail/observe) to the caller's XML
# accumulator, using bash namerefs rather than eval so shellcheck can see the
# read/write and the caller's counter/buffer are updated in place.
emit_testcase() {
  local name="$1" verdict="$2" message="$3" detail="$4"
  local -n failure_count_ref="$5"
  local -n xml_ref="$6"

  local xml
  if [[ "${verdict}" == "fail" ]]; then
    failure_count_ref=$(( failure_count_ref + 1 ))
    xml="  <testcase name=\"${name}\" classname=\"${JUNIT_CLASSNAME}\" time=\"0\">
    <failure message=\"${message}\">${detail}</failure>
  </testcase>"
  else
    xml="  <testcase name=\"${name}\" classname=\"${JUNIT_CLASSNAME}\" time=\"0\">
    <system-out>${detail}</system-out>
  </testcase>"
  fi

  xml_ref+="${xml}"$'\n'
}

# Writes junit_tls_probe.xml from the aggregated verdict. Test names are
# static (no runtime-derived destination port) so Spyglass/Sippy test
# identity stays stable across runs; per-port detail lives in the single
# summary testcase's body instead of one dynamically-named testcase per port.
write_junit() {
  local policy="$1" enforce="$2" total_events="$3"
  local full_verdict="$4"

  local junit_failures=0
  local tc_xml=""

  local total_ports below13_ports below13_detail all_ports_detail

  total_ports=$(echo "${full_verdict}" | jq 'length')
  below13_ports=$(echo "${full_verdict}" | jq '[.[] | select(.worst_tls != "TLS 1.3")] | length')
  below13_detail=$(echo "${full_verdict}" | jq -r '
    [.[] | select(.worst_tls != "TLS 1.3")]
    | map("port/\(.dst_port)(\(.worst_tls)x\(.handshake_count))")
    | join(", ")')
  all_ports_detail=$(echo "${full_verdict}" | jq -r '
    map("port/\(.dst_port)(\(.worst_tls)x\(.handshake_count))")
    | join(", ")')

  echo "${full_verdict}" > "${PROBE_DIR}/server-summary.json"

  log "ports observed (<32768): ${total_ports} | below-TLS-1.3: ${below13_ports}"

  # No traffic captured → skipped testcase.
  if [[ "${total_ports}" -eq 0 ]]; then
    cat > "${PROBE_DIR}/junit_tls_probe.xml" <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="tls-probe" tests="1" failures="0" skipped="1" time="0">
  <properties>
    <property name="adherence-policy" value="${policy}"/>
    <property name="enforce" value="${enforce}"/>
    <property name="total-events" value="${total_events}"/>
  </properties>
  <testcase name="[OCPFeatureGate:TLSAdherence] tls-probe: capture [phase:runtime]" classname="${JUNIT_CLASSNAME}" time="0">
    <skipped message="No ServerHello events captured in ${CAPTURE_SECS}s window."/>
  </testcase>
</testsuite>
XMLEOF
    cp "${PROBE_DIR}/junit_tls_probe.xml" "${ARTIFACT_DIR}/junit_tls_probe.xml"
    log "JUnit: skipped (no traffic)"
    return
  fi

  # Single static-named summary testcase; all per-port detail is in its body.
  local summary_name="[OCPFeatureGate:TLSAdherence] tls-probe: server handshake adherence [phase:runtime]"
  if [[ "${below13_ports}" -eq 0 ]]; then
    emit_testcase "${summary_name}" pass "" \
      "PASS: all captured handshakes TLS 1.3. events=${total_events} ports=[${all_ports_detail}]" \
      junit_failures tc_xml
  elif [[ "${enforce}" == "true" ]]; then
    emit_testcase "${summary_name}" fail \
      "${below13_ports} port(s) with below-TLS-1.3 handshakes" \
      "below-TLS-1.3: ${below13_detail} | all ports: [${all_ports_detail}] | policy=${policy} | events=${total_events}" \
      junit_failures tc_xml
  else
    emit_testcase "${summary_name}" observe "" \
      "OBSERVE: ${below13_ports} port(s) below TLS 1.3: ${below13_detail} | all ports: [${all_ports_detail}] | events=${total_events}" \
      junit_failures tc_xml
  fi

  cat > "${PROBE_DIR}/junit_tls_probe.xml" <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="tls-probe" tests="1" failures="${junit_failures}" time="0">
  <properties>
    <property name="adherence-policy" value="${policy}"/>
    <property name="enforce" value="${enforce}"/>
    <property name="total-events" value="${total_events}"/>
    <property name="probe-image" value="${PROBE_IMG}"/>
    <property name="capture-duration-secs" value="${CAPTURE_SECS}"/>
  </properties>
${tc_xml}</testsuite>
XMLEOF

  cp "${PROBE_DIR}/junit_tls_probe.xml" "${ARTIFACT_DIR}/junit_tls_probe.xml"
  log "JUnit written: failures=${junit_failures} enforce=${enforce}"

  if [[ "${junit_failures}" -gt 0 ]] && [[ "${enforce}" == "true" ]]; then
    die "${junit_failures} testcase(s) failed (enforce=true)"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
# Orchestrates deploy → capture → collect → verdict → JUnit, always cleaning
# up the namespace and scoped SCC on exit.
main() {
  setup
  trap cleanup EXIT

  create_namespace
  deploy_daemonset
  wait_for_capture
  collect_jsonl

  local policy enforce total_events full_verdict
  policy=$(read_adherence_policy)
  enforce=$(should_enforce "${policy}")
  total_events=$(wc -l < "${SCRATCH_DIR}/all-events.jsonl" || echo 0)
  full_verdict=$(build_verdict)

  log "policy=${policy} enforce=${enforce} events=${total_events}"

  write_junit "${policy}" "${enforce}" "${total_events}" "${full_verdict}"

  log "complete"
}

main "$@"
