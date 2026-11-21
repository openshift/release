#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Required feature-mode guard: before the tests run, verify that ARP/NDP flood
# suppression for user-defined networks is requested and that ovnkube on every
# current ovnkube-node pod runs with it. General cluster readiness is left to
# the test step that follows. Read-only: oc exec only reads process arguments
# and /proc metadata. The step is a no-op unless DISABLE_UDN_ARP_NDP_FLOOD is
# set to "true" by the job, so it can sit in a shared workflow without
# affecting other lanes.

# Only "" (feature not requested on this lane) and "true" are accepted; any
# other value is a misconfiguration and fails rather than being interpreted.
# The error is written directly, not through die(): a step that never activated
# must not create the summary artifact.
case "${DISABLE_UDN_ARP_NDP_FLOOD:-}" in
  "") exit 0 ;;
  "true") ;;
  *) echo "ERROR: DISABLE_UDN_ARP_NDP_FLOOD must be \"true\" or unset, got '${DISABLE_UDN_ARP_NDP_FLOOD}'" >&2; exit 1 ;;
esac

readonly CNO_NS=openshift-network-operator
readonly OVERRIDES_CM=ovn-kubernetes-config-overrides
readonly KEY=disable-udn-arp-ndp-flood
readonly OVN_NS=openshift-ovn-kubernetes
readonly NODE_DS=ovnkube-node
readonly NODE_CONTAINER=ovnkube-controller
readonly FLAG=--disable-udn-arp-ndp-flood

readonly CALL_TIMEOUT=60 # upper bound for one oc call
readonly POLL=10         # seconds between attempts
readonly KILL_GRACE=10   # a call still running this long after SIGTERM is killed
# oc calls are capped by the remaining wait and killed KILL_GRACE seconds after
# a timeout, so they end within MAX_TIMEOUT + KILL_GRACE seconds, well below the
# 20m ref timeout. Local processing between calls is not separately limited.
readonly MAX_TIMEOUT=1080
readonly TIMEOUT="${OVN_NOFLOOD_VERIFY_TIMEOUT_SECONDS:-900}"
readonly SUMMARY="${ARTIFACT_DIR:-/tmp}/ovn-noflood-verify.txt"

# Diagnostics go to stderr and the summary, never to stdout, so command
# substitutions only capture data.
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${SUMMARY}" >&2; }
die() { log "ERROR: $*"; exit 1; }

# classify maps oc stderr to a fixed category. Raw error text is never logged:
# it can carry host names, addresses, proxy details or credentials.
classify() {
  local text
  text=$(head -c 4096 "$1" | tr '[:upper:]' '[:lower:]')
  case "${text}" in
    *"command terminated with exit code"*) echo "the in-pod command exited non-zero" ;;
    *unauthorized*|*"must be logged in"*|*"provide credentials"*) echo "unauthorized" ;;
    *forbidden*) echo "forbidden" ;;
    *notfound*|*"not found"*) echo "not found" ;;
    *"unable to connect"*|*"connection refused"*|*"no such host"*|*"i/o timeout"*|*proxyconnect*|*"tls handshake"*|*x509*) echo "connection error" ;;
    *"unable to upgrade connection"*|*"error executing"*) echo "exec error" ;;
    *) echo "unclassified error" ;;
  esac
}

if [[ ! "${TIMEOUT}" =~ ^[1-9][0-9]{0,3}$ ]] || ((TIMEOUT > MAX_TIMEOUT)); then
  die "OVN_NOFLOOD_VERIFY_TIMEOUT_SECONDS must be an integer from 1 to ${MAX_TIMEOUT}"
fi

[[ -n "${SHARED_DIR:-}" ]] || die "SHARED_DIR is not set"
[[ -r "${SHARED_DIR}/kubeconfig" ]] || die "the target cluster kubeconfig is not available in SHARED_DIR"
# Target the installed cluster explicitly, never the build farm.
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # The proxy settings may contain credentials; never trace them.
  set +x
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/proxy-conf.sh"
fi

readonly DEADLINE=$((SECONDS + TIMEOUT))
remaining() { echo $((DEADLINE - SECONDS)); }

# oc_ runs one read-only oc call bounded by the call timeout, the remaining
# budget and the kill grace. Output is printed only when the call finished
# before the deadline; a late result is rejected.
oc_() {
  local left budget rc=0 out errfile
  left=$(remaining)
  budget=$((CALL_TIMEOUT < left ? CALL_TIMEOUT : left))
  if ((budget <= 0)); then
    log "deadline reached before: oc $1 $2"
    return 124
  fi
  errfile=$(mktemp)
  out=$(timeout --kill-after="${KILL_GRACE}" "${budget}" oc "$@" 2>"${errfile}") || rc=$?
  if ((SECONDS >= DEADLINE)); then
    rm -f "${errfile}"
    log "oc $1 $2 returned at or after the deadline; result rejected"
    return 124
  fi
  if ((rc != 0)); then
    if ((rc == 124 || rc == 137)); then
      log "oc $1 $2 did not finish within ${budget}s"
    else
      log "oc $1 $2 failed (rc=${rc}): $(classify "${errfile}")"
    fi
    rm -f "${errfile}"
    return "${rc}"
  fi
  rm -f "${errfile}"
  printf '%s' "${out}"
}

# desired_value prints "absent", "missing-key" or "value=<v>" for the override.
desired_value() {
  local out
  # The template distinguishes a missing ConfigMap (empty output, thanks to
  # --ignore-not-found) from an existing one without the key; a jsonpath
  # could not, both would come back as an empty string.
  out=$(oc_ get configmap -n "${CNO_NS}" "${OVERRIDES_CM}" --ignore-not-found \
    -o go-template='{{if .data}}{{with index .data "'"${KEY}"'"}}value={{.}}{{else}}missing-key{{end}}{{else}}missing-key{{end}}') || return 1
  if [[ -z "${out}" ]]; then
    echo absent
  else
    printf '%s' "${out}"
  fi
}

# parse_bool follows CNO: the value is trimmed and parsed like strconv.ParseBool.
parse_bool() {
  local v=$1
  # Trim outer whitespace like strings.TrimSpace: each expansion first
  # computes the run to remove (${v%%[![:space:]]*} leaves only the leading
  # whitespace, ${v##*[![:space:]]} only the trailing) and then strips it.
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "${v}" in
    1|t|T|TRUE|true|True) echo true ;;
    0|f|F|FALSE|false|False) echo false ;;
    "") echo empty ;;
    *) echo invalid ;;
  esac
}

# check_desired fails the step for a definitive negative setting and returns 1
# when the value could not be read (retried).
check_desired() {
  local d
  d=$(desired_value) || return 1
  case "${d}" in
    absent) die "${CNO_NS}/${OVERRIDES_CM} does not exist; the install-time manifest was not applied" ;;
    missing-key) die "${CNO_NS}/${OVERRIDES_CM} has no ${KEY} key" ;;
  esac
  case "$(parse_bool "${d#value=}")" in
    true) return 0 ;;
    false) die "${CNO_NS}/${OVERRIDES_CM} sets ${KEY} to false" ;;
    empty) die "${CNO_NS}/${OVERRIDES_CM} sets ${KEY} to an empty value" ;;
    *) die "${CNO_NS}/${OVERRIDES_CM} sets ${KEY} to an invalid boolean" ;;
  esac
}

# CHECK_ARGS is a static Bash program run in each ovnkube-controller container.
# The pods use the host PID namespace, so processes of the whole node are
# visible; each candidate process must therefore share the cgroup of the
# container this program runs in, which excludes processes owned by other
# containers and pods (when the container uses a private cgroup namespace all
# processes report the same trivial path and the filter degrades to a no-op,
# never to a false exclusion). It reads each command line NUL-separated
# straight from /proc and exits 0 only when exactly one process of this
# container is ovnkube with the argument --init-node and names the flag exactly
# once, as --disable-udn-arp-ndp-flood or --disable-udn-arp-ndp-flood=true. Any
# other value, a repeated or single-dash flag, or a second such process makes
# it exit non-zero. The flag is spelled out here rather than taken from FLAG so
# that nothing is inserted into the program; keep both in step.
# shellcheck disable=SC2016 # expanded by the remote shell
readonly CHECK_ARGS='
# If our own cgroup cannot be read, scoping is impossible: the filter is
# then skipped rather than excluding every process (never a false
# exclusion).
own_cgroup=x-unreadable
scope=0
if [ -r /proc/self/cgroup ]; then
  scope=1
  own_cgroup=
  while IFS= read -r cgl; do printf -v own_cgroup "%s%s\n" "$own_cgroup" "$cgl"; done < /proc/self/cgroup
fi
init_nodes=0
enabled=0
for f in /proc/[0-9]*/cmdline; do
  [ -r "$f" ] || continue
  p=${f%/cmdline}
  if [ "$scope" = 1 ]; then
    pcg=x-unreadable
    if [ -r "$p/cgroup" ]; then
      pcg=
      while IFS= read -r cgl; do printf -v pcg "%s%s\n" "$pcg" "$cgl"; done < "$p/cgroup"
    fi
    [ "$pcg" = "$own_cgroup" ] || continue
  fi
  # Read the NUL-separated arguments; "|| [[ -n "$a" ]]" also accepts a final
  # argument whose cmdline is not NUL-terminated.
  args=()
  { while IFS= read -r -d "" a || [[ -n "$a" ]]; do args+=("$a"); done < "$f"; } 2>/dev/null || continue
  [[ ${#args[@]} -gt 0 && "${args[0]##*/}" == ovnkube ]] || continue
  init=0
  seen=0
  exact=0
  # Arguments after argv[0], which was matched above.
  for a in "${args[@]:1}"; do
    case "$a" in
      --init-node) init=1 ;;
      # Only the two exact enabled spellings set exact; every other form of
      # the flag (=false, a single dash, a repeat) raises seen without exact,
      # and the final test accepts only seen=1 together with exact=1.
      --disable-udn-arp-ndp-flood|--disable-udn-arp-ndp-flood=true) seen=$((seen + 1)); exact=1 ;;
      --disable-udn-arp-ndp-flood=*|-disable-udn-arp-ndp-flood|-disable-udn-arp-ndp-flood=*) seen=$((seen + 1)) ;;
    esac
  done
  [[ $init -eq 1 ]] || continue
  init_nodes=$((init_nodes + 1))
  if [[ $seen -eq 1 && $exact -eq 1 ]]; then enabled=$((enabled + 1)); fi
done
[[ $init_nodes -eq 1 && $enabled -eq 1 ]]
'

# census_pods reads the current DaemonSet identity and its eligible pod set.
# It sets DS_UID, DS_DESIRED and CENSUS (one "name|node" line per eligible
# pod, in listing order) and returns 1 while the set is not yet complete: no
# usable DaemonSet status, a pod that is terminating, not Running or not
# scheduled, two pods on one node, or a count below the desired one.
census_pods() {
  local status uid desired pods name owner deleting phase node count=0
  local -A on_node=()
  status=$(oc_ get daemonset -n "${OVN_NS}" "${NODE_DS}" \
    -o 'jsonpath={.metadata.uid}|{.status.desiredNumberScheduled}') || return 1
  IFS='|' read -r uid desired <<<"${status}"
  if [[ -z "${uid}" || ! "${desired}" =~ ^[1-9][0-9]*$ ]]; then
    log "${NODE_DS} has no UID or positive desired pod count yet"
    return 1
  fi
  pods=$(oc_ get pods -n "${OVN_NS}" -l app=ovnkube-node \
    -o 'jsonpath={range .items[*]}{.metadata.name}|{.metadata.ownerReferences[?(@.controller==true)].uid}|{.metadata.deletionTimestamp}|{.status.phase}|{.spec.nodeName}{"\n"}{end}') || return 1
  CENSUS=""
  while IFS='|' read -r name owner deleting phase node; do
    [[ -n "${name}" && "${owner}" == "${uid}" ]] || continue
    if [[ -n "${deleting}" || "${phase}" != Running || -z "${node}" ]]; then
      log "pod ${name} is not eligible yet (it must be scheduled, Running and not terminating)"
      return 1
    fi
    if [[ -n "${on_node[${node}]:-}" ]]; then
      log "pods ${on_node[${node}]} and ${name} run on the same node"
      return 1
    fi
    on_node[${node}]="${name}"
    CENSUS+="${name}|${node}"$'\n'
    count=$((count + 1))
  done <<<"${pods}"
  if ((count != desired)); then
    log "found ${count} running ${NODE_DS} pods of the current DaemonSet, want ${desired}"
    return 1
  fi
  DS_UID="${uid}"
  DS_DESIRED="${desired}"
}

# check_pods runs CHECK_ARGS in every pod of a complete, stable census. After
# the checks, the census is taken again and must be unchanged: a pod replaced
# while its neighbours were being checked was never verified, so the whole
# pass is discarded and retried.
check_pods() {
  local name _ node
  census_pods || return 1
  local uid="${DS_UID}" desired="${DS_DESIRED}" census="${CENSUS}"
  while IFS='|' read -r name _; do
    [[ -n "${name}" ]] || continue
    if ! oc_ exec "${name}" -n "${OVN_NS}" -c "${NODE_CONTAINER}" -- /bin/bash -c "${CHECK_ARGS}" >/dev/null; then
      log "pod ${name}: could not verify that ovnkube --init-node runs with exactly one enabled ${FLAG}"
      return 1
    fi
  done <<<"${census}"
  census_pods || return 1
  if [[ "${DS_UID}" != "${uid}" || "${DS_DESIRED}" != "${desired}" || "${CENSUS}" != "${census}" ]]; then
    log "the ${NODE_DS} pod set changed while it was being verified; retrying"
    return 1
  fi
}

verify_once() {
  check_desired && check_pods && check_desired
}

NODE_PODS=0
log "verifying ${KEY} on the installed cluster (deadline ${TIMEOUT}s)"
until verify_once; do
  left=$(remaining)
  if ((left <= 0)); then
    die "${KEY} was not effective within ${TIMEOUT}s"
  fi
  sleep $((POLL < left ? POLL : left))
done
# Every call already finished before the deadline; also require the whole
# pass, including its evaluation, to have finished before it.
if ((SECONDS >= DEADLINE)); then
  die "the passing verification finished at or after the ${TIMEOUT}s deadline; not reporting success"
fi
NODE_PODS=$(grep -c . <<<"${CENSUS}") # the stable, fully verified census
log "${KEY} is requested and ovnkube runs with ${FLAG} on all ${NODE_PODS} ${NODE_DS} pods"
