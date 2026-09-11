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
readonly CAPTURES_DIR="${PROBE_DIR}/captures"
readonly JUNIT_CLASSNAME="tls.probe.adherence.runtime"

# ── helpers ───────────────────────────────────────────────────────────────────
log() { echo "=== tls-probe: $* ==="; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ── setup ─────────────────────────────────────────────────────────────────────
setup() {
  if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
  fi
  mkdir -p "${CAPTURES_DIR}"
}

# ── cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
  log "cleanup"
  oc delete namespace "${NS}" --ignore-not-found --wait=false || true
}

# ── 1. namespace + service account ───────────────────────────────────────────
create_namespace() {
  log "creating namespace ${NS}"
  oc delete namespace "${NS}" --ignore-not-found --wait=true --timeout=120s || true

  oc create -f - <<EOF
# Isolated namespace; pod-security labels grant privileged enforcement so the
# eBPF container can use hostNetwork/hostPID without the admission webhook
# blocking it. scc.podSecurityLabelSync=false prevents the SCC controller
# from overriding those labels after creation.
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
# Identity the DaemonSet pods run as; SCC binding targets this SA.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tls-probe
  namespace: ${NS}
EOF

  # Grant the privileged SCC so pods can use hostNetwork, hostPID, hostPath
  # mounts, and a privileged security context (required for eBPF TC attach).
  oc adm policy add-scc-to-user privileged -z tls-probe -n "${NS}"
  sleep 10  # SCC propagation — binding is async; skip and pods will be rejected
}

# ── 2. DaemonSet ──────────────────────────────────────────────────────────────
deploy_daemonset() {
  log "deploying DaemonSet (image: ${PROBE_IMG})"

  oc create -f - <<EOF
# One pod per node; captures TLS handshakes on all interfaces for CAPTURE_SECS
# then exits cleanly (--duration). hostNetwork+hostPID give the eBPF program
# visibility into all node traffic and process attribution.
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
          privileged: true  # required: CAP_BPF, CAP_NET_ADMIN, CAP_PERFMON
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
      tolerations:
      - operator: Exists
        effect: NoSchedule  # schedule on master/infra nodes too
      - operator: Exists
        effect: NoExecute
EOF

  oc rollout status daemonset/tls-probe -n "${NS}" --timeout=5m || {
    oc describe daemonset/tls-probe -n "${NS}" || true
    oc get events -n "${NS}" --sort-by='.lastTimestamp' | tail -20 || true
    die "DaemonSet failed to roll out — probe image may not be pullable"
  }
  log "DaemonSet ready on $(oc get pods -n "${NS}" -l app.kubernetes.io/name=tls-probe --no-headers | wc -l) node(s)"
}

# ── 3. capture window ─────────────────────────────────────────────────────────
wait_for_capture() {
  log "waiting for ${CAPTURE_SECS}s capture to complete (probe exits cleanly on --duration)"
  oc wait pod -n "${NS}" -l app.kubernetes.io/name=tls-probe \
    --for=jsonpath='{.status.phase}'=Succeeded \
    --timeout="$(( CAPTURE_SECS + 60 ))s" || {
    echo "WARN: pods did not reach Succeeded; collecting available data"
    oc get pods -n "${NS}" -o wide || true
  }
}

# ── 4. collect JSONL ──────────────────────────────────────────────────────────
collect_jsonl() {
  log "collecting JSONL from DaemonSet pods"
  local pod_count=0

  while IFS= read -r pod; do
    [[ -z "${pod}" ]] && continue
    local node
    node=$(oc get pod "${pod}" -n "${NS}" -o jsonpath='{.spec.nodeName}' 2>/dev/null \
      || echo "unknown-${pod_count}")
    # Pod stdout mixes probe log lines with JSON events; keep only JSON lines.
    oc logs "${pod}" -n "${NS}" 2>/dev/null \
      | grep -E '^\{' > "${CAPTURES_DIR}/${node//\//-}.jsonl" || true
    pod_count=$(( pod_count + 1 ))
  done < <(oc get pods -n "${NS}" -l app.kubernetes.io/name=tls-probe \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  cat "${CAPTURES_DIR}"/*.jsonl > "${PROBE_DIR}/all-events.jsonl" 2>/dev/null \
    || touch "${PROBE_DIR}/all-events.jsonl"
  log "collected from ${pod_count} pod(s) — $(wc -l < "${PROBE_DIR}/all-events.jsonl") events"
}

# ── 5. read cluster TLS policy ────────────────────────────────────────────────
read_adherence_policy() {
  oc get apiserver cluster -o jsonpath='{.spec.tlsAdherence}' 2>/dev/null || echo ""
}

should_enforce() {
  local policy="$1"
  [[ "${ENFORCE}" == "true" ]] \
    && [[ "${policy}" != "" ]] \
    && [[ "${policy}" != "NoOpinion" ]] \
    && [[ "${policy}" != "LegacyAdheringComponentsOnly" ]] \
    && echo "true" || echo "false"
}

# ── 6. verdict ───────────────────────────────────────────────────────────────
# Aggregates ServerHello events by destination port — the negotiated version
# is on the ServerHello. ClientHello data (offered versions, cipher suites,
# key share groups) is present in the capture but not evaluated here; client
# negotiation analysis requires pairing CH→SH per connection.
# Two filters keep the Spyglass testcase count manageable:
#   - ephemeral client ports (>= 32768) are excluded
#   - per-port testcases only for ports seen >= 2 times (recurring services)
# A summary testcase covers all below-TLS-1.3 flows so nothing is silently dropped.
build_verdict() {
  local all_events="${PROBE_DIR}/all-events.jsonl"

  jq -rsc '
    map(select(.handshake_type == "ServerHello")) |
    map(select((.dst | split(":")[1] // "0" | tonumber) < 32768)) |
    group_by(.dst | split(":")[1] // "0") |
    map({
      dst_port: (.[0].dst | split(":")[1] // "0"),
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
emit_testcase() {
  local name="$1" verdict="$2" message="$3" detail="$4"
  local failure_count_ref="$5"
  local xml_ref="$6"

  local xml
  if [[ "${verdict}" == "fail" ]]; then
    eval "(( ${failure_count_ref}++ )) || true"
    xml="  <testcase name=\"${name}\" classname=\"${JUNIT_CLASSNAME}\" time=\"0\">
    <failure message=\"${message}\">${detail}</failure>
  </testcase>"
  else
    xml="  <testcase name=\"${name}\" classname=\"${JUNIT_CLASSNAME}\" time=\"0\">
    <system-out>${detail}</system-out>
  </testcase>"
  fi

  eval "${xml_ref}+=\"\${xml}\$'\\n'\""
}

write_junit() {
  local policy="$1" enforce="$2" total_events="$3"
  local full_verdict="$4"

  local junit_failures=0
  local tc_xml=""

  local total_ports below13_ports below13_detail recurring_json

  total_ports=$(echo "${full_verdict}" | jq 'length')
  below13_ports=$(echo "${full_verdict}" | jq '[.[] | select(.worst_tls != "TLS 1.3")] | length')
  below13_detail=$(echo "${full_verdict}" | jq -r '
    [.[] | select(.worst_tls != "TLS 1.3")]
    | map("port/\(.dst_port)(\(.worst_tls)x\(.handshake_count))")
    | join(", ")')
  recurring_json=$(echo "${full_verdict}" | jq '[.[] | select(.handshake_count >= 2)]')

  echo "${full_verdict}"   > "${PROBE_DIR}/server-summary-full.json"
  echo "${recurring_json}" > "${PROBE_DIR}/server-summary.json"

  local entry_count
  entry_count=$(echo "${recurring_json}" | jq 'length')

  log "ports observed (<32768): ${total_ports} | recurring (count>=2): ${entry_count} | below-TLS-1.3: ${below13_ports}"

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

  # Per-port testcases (recurring services only).
  while IFS=$'\t' read -r dst_port worst_tls count versions; do
    local name="[OCPFeatureGate:TLSAdherence] tls-probe: port/${dst_port} [phase:runtime]"
    if [[ "${worst_tls}" == "TLS 1.3" ]]; then
      emit_testcase "${name}" pass "" \
        "PASS: ${count} handshake(s) on port ${dst_port} — all TLS 1.3." \
        junit_failures tc_xml
    elif [[ "${enforce}" == "true" ]]; then
      emit_testcase "${name}" fail \
        "Below-TLS-1.3 on port ${dst_port} (worst: ${worst_tls})" \
        "worst=${worst_tls} versions=[${versions}] count=${count} policy=${policy}" \
        junit_failures tc_xml
    else
      emit_testcase "${name}" observe "" \
        "OBSERVE: below-TLS-1.3 on port ${dst_port} worst=${worst_tls} versions=[${versions}] count=${count}" \
        junit_failures tc_xml
    fi
  done < <(echo "${recurring_json}" \
    | jq -r '.[] | [.dst_port, .worst_tls, (.handshake_count|tostring), (.tls_versions|join(","))] | @tsv')

  # Summary testcase: all below-TLS-1.3 flows, including single-handshake.
  local summary_name="[OCPFeatureGate:TLSAdherence] tls-probe: all handshakes [phase:runtime]"
  if [[ "${below13_ports}" -eq 0 ]]; then
    emit_testcase "${summary_name}" pass "" \
      "PASS: all captured handshakes TLS 1.3. events=${total_events}" \
      junit_failures tc_xml
  elif [[ "${enforce}" == "true" ]]; then
    emit_testcase "${summary_name}" fail \
      "${below13_ports} port(s) with below-TLS-1.3 handshakes" \
      "ports: ${below13_detail} | policy=${policy} | events=${total_events}" \
      junit_failures tc_xml
  else
    emit_testcase "${summary_name}" observe "" \
      "OBSERVE: ${below13_ports} port(s) below TLS 1.3: ${below13_detail} | events=${total_events}" \
      junit_failures tc_xml
  fi

  local total_tests=$(( entry_count + 1 ))
  cat > "${PROBE_DIR}/junit_tls_probe.xml" <<XMLEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="tls-probe" tests="${total_tests}" failures="${junit_failures}" time="0">
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
  log "JUnit written: tests=${total_tests} failures=${junit_failures} enforce=${enforce}"

  if [[ "${junit_failures}" -gt 0 ]] && [[ "${enforce}" == "true" ]]; then
    die "${junit_failures} testcase(s) failed (enforce=true)"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
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
  total_events=$(wc -l < "${PROBE_DIR}/all-events.jsonl" || echo 0)
  full_verdict=$(build_verdict)

  log "policy=${policy} enforce=${enforce} events=${total_events}"

  write_junit "${policy}" "${enforce}" "${total_events}" "${full_verdict}"

  log "complete"
}

main "$@"
