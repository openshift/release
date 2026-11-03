#!/bin/bash
set -euo pipefail
set +x
# A standalone ref can run once; the perf workflow stages the same runner for its iteration loop.
if [[ ${NETPERF_STAGE_ONLY:-false} == true ]]; then
  cp "${BASH_SOURCE[0]}" "${SHARED_DIR}/microshift-perf-netperf.sh"
  exit 0
fi
owns_tools=false
[[ -n ${PERF_TOOLS_DIR:-} ]] || owns_tools=true
# shellcheck source=/dev/null
source "${SHARED_DIR}/microshift-perf-library.sh"
# Match openshift-qe-network-perf: native and metadata upload use wrapper defaults after a successful probe.
# k8s-netperf v0.1.43 does not verify TLS; all native output is redacted before logging/archiving.
export ES_SERVER=""
if jq -e '.enabled' "${SHARED_DIR}/microshift-perf-es-status.json" >/dev/null; then
  ES_SERVER=$(cat "${SHARED_DIR}/microshift-perf-es-url")
fi
unset ES_INDEX ES_METADATA_INDEX
prepare_tools
perf_dir="${PERF_TOOLS_DIR:?}"
PROM_URL=${MICROSHIFT_PROMETHEUS_URL:-$(cat "${SHARED_DIR}/prometheus_url")}
export PROMETHEUS_URL="$PROM_URL" NETPERF_VERSION
export UUID=${NETPERF_UUID:-$(uuidgen)}
export LOCAL=true METRICS=true WORKLOAD=full-run.yaml CLEAN_UP=true
owns_work=true
if [[ -n ${NETPERF_WORK_DIR:-} ]]; then
  net_dir=$NETPERF_WORK_DIR
  owns_work=false
  mkdir -p "$net_dir"
else
  net_dir=$(mktemp -d /tmp/microshift-netperf.XXXXXX)
fi
child=""
log_pid=""
mkdir -p "$ARTIFACT_DIR"
# shellcheck disable=SC2329 # EXIT and signal handlers invoke this function.
cleanup_netperf() {
  local rc=$?
  trap - EXIT
  trap '' INT TERM
  if [[ -n $child ]]; then
    kill -TERM -- "-$child" 2>/dev/null || true
    sleep 2
    kill -KILL -- "-$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  rm -f "$net_dir/.native-pgid"
  # Redaction is re-created after a signal; the original logging pipeline may have been interrupted.
  collect_netperf_results "$net_dir/workloads/network-perf-v2" "$ARTIFACT_DIR" || {
    echo 'WARNING: partial netperf archive exceeded its bound or failed'; if ((rc==0)); then rc=1; fi;
  }
  if $owns_work; then rm -rf "$net_dir"; fi
  if $owns_tools; then rm -rf "$perf_dir"; fi
  exit "$rc"
}
trap cleanup_netperf EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp -a "$perf_dir/e2e/." "$net_dir/"
cd "$net_dir/workloads/network-perf-v2"
# Isolate the workload process group so EXIT cleanup can stop it before copying its partial results.
exec {log_fd}> >(redact | tee "$ARTIFACT_DIR/netperf.log")
log_pid=$!
setsid timeout -k 15 "$NETPERF_TIMEOUT_SECONDS" bash ./run.sh >&"$log_fd" 2>&1 &
child=$!
printf '%s\n' "$child" > "$net_dir/.native-pgid"
exec {log_fd}>&-
rc=0
wait "$child" || rc=$?
child=""
wait "$log_pid" || true
exit "$rc"
