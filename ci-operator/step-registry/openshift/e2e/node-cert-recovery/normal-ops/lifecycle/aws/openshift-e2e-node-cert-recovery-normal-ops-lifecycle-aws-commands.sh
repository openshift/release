#!/bin/bash
# jq filters use $vars inside single quotes on purpose; the small predicates are called through wait_for.
# shellcheck disable=SC2016,SC2329
# Node cert recovery, normal operation (OCPSTRAT-1346): with the recovery toggle on and no power-off,
# routine node lifecycle events must be approved by the routine approvers, never by the KCM recovery
# approvers (reason KCMRecoveryApprove). Then one node loses its client cert, the case the client
# approver exists for, and must be re-admitted only after its heartbeat has been stale for 5 minutes.
# Ported from the OCPSTRAT-1346 e2e harness (toggle-on-normal-ops).
set -o nounset
set -o errexit
set -o pipefail

readonly SIGNER_CLIENT=kubernetes.io/kube-apiserver-client-kubelet
readonly SIGNER_SERVING=kubernetes.io/kubelet-serving
readonly BOOTSTRAPPER=system:serviceaccount:openshift-machine-config-operator:node-bootstrapper
readonly APPROVER_REASON=KCMRecoveryApprove
readonly MACHINE_APPROVER_REASON=NodeCSRApprove
readonly RENEWAL_REASON=AutoApproved
readonly APPROVER_ENABLED_EVENT=NodeCertRecoveryEnabled
readonly TOGGLE_NS=openshift-config
readonly TOGGLE_NAME=node-client-cert-recovery
readonly MAPI_NS=openshift-machine-api
readonly KCM_NS=openshift-kube-controller-manager
readonly MA_NS=openshift-cluster-machine-approver
readonly RESET_MIN_DELAY_S=240
OUT="${ARTIFACT_DIR:-/tmp}/normal-ops"
STEPS="${OUT}/steps"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
die() {
  log "ERROR: $*"
  exit 1
}
now() { date -u +%s; }
dur() {
  local n=${1%[smhd]}
  case ${1: -1} in s) echo "$n" ;; m) echo $((n * 60)) ;; h) echo $((n * 3600)) ;; d) echo $((n * 86400)) ;; *) echo "$1" ;; esac
}
timeline() { printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >>"${OUT}/timeline.tsv"; }
fail() { # inside a step: record why it failed and end it
  echo "$*" >>"${STEPS}/${STEP}.detail"
  log "FAIL: $*"
  exit 1
}
wait_for() { # timeout-seconds description command...
  local end=$(($(now) + $1)) desc=$2
  shift 2
  until "$@"; do
    (($(now) < end)) || { log "timed out waiting for ${desc}"; return 1; }
    sleep 15
  done
  log "ok: ${desc}"
}
node_ready() { [[ $(oc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]; }
node_gone() { ! oc get node "$1" >/dev/null 2>&1; }
lease_gone() { ! oc get lease -n kube-node-lease "$1" >/dev/null 2>&1; }
# -n default: in a CI pod oc otherwise uses the pod's own namespace, which the cluster doesn't have.
debug_node() { timeout 300 oc debug "node/$1" -n default -q -- chroot /host sh -c "$2"; }
# Restart the kubelet 5s after oc debug returns, so the restart doesn't kill the debug pod mid-command.
move_aside_and_restart() { # node file
  debug_node "$1" "set -e; cd /var/lib/kubelet/pki; mv $2 $2.e2e-bak; systemd-run --on-active=5 systemctl restart kubelet"
}

# oc get csr -o json on stdin -> kubelet CSRs as [{name, created, signer, username, node, state, reason, approved_at}].
# A bootstrap client CSR names its node only in the x509 subject, so decode those.
csr_view() {
  local raw cn
  raw=$(cat)
  cn=$(jq -r --arg c "${SIGNER_CLIENT}" --arg b "${BOOTSTRAPPER}" \
    '.items[] | select(.spec.signerName == $c and .spec.username == $b) | [.metadata.name, .spec.request] | @tsv' <<<"$raw" |
    while IFS=$'\t' read -r name req; do
      printf '%s\t%s\n' "$name" "$(base64 -d <<<"$req" | openssl req -noout -subject 2>/dev/null | sed -nE 's/.*CN ?= ?([^,/]+).*/\1/p' | sed -E 's/ +$//')"
    done | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries')
  jq -c --argjson cn "$cn" --arg c "${SIGNER_CLIENT}" --arg s "${SIGNER_SERVING}" '
    [.items[] | select(.spec.signerName == $c or .spec.signerName == $s)
     | ([.status.conditions[]? | select(.type == "Approved")][0] // null) as $a
     | {name: .metadata.name, created: .metadata.creationTimestamp, signer: .spec.signerName, username: .spec.username,
        node: ((if (.spec.username | startswith("system:node:")) then .spec.username else ($cn[.metadata.name] // "") end) | ltrimstr("system:node:")),
        state: (if any(.status.conditions[]?; .type == "Denied" or .type == "Failed") then "Denied" elif $a then "Approved" else "Pending" end),
        reason: ($a.reason // null), approved_at: ($a.lastTransitionTime // $a.lastUpdateTime // null)}]' <<<"$raw"
}
csr_json() { oc get csr -o json | csr_view; }
approval_events() {
  oc get events -A -o json | jq -c '[.items[] | select(.reason == "KubeletClientCSRApproved" or .reason == "KubeletServingCSRApproved")
    | {reason, message, last: ((.lastTimestamp // .eventTime // .firstTimestamp) | sub("\\.[0-9]+"; ""))}]'
}

# Record every recovery approval as it happens, so the timeline places it between the step events.
watch_csrs() {
  local seen=" " c n
  while :; do
    if c=$(csr_json 2>/dev/null); then
      jq . <<<"$c" >"${OUT}/csrs.json.tmp" && mv "${OUT}/csrs.json.tmp" "${OUT}/csrs.json"
      for n in $(jq -r --arg r "${APPROVER_REASON}" --arg t "${SINCE}" '.[] | select(.reason == $r and .created >= $t) | "\(.name)/\(.node)"' <<<"$c"); do
        [[ $seen == *" $n "* ]] && continue
        seen+="$n "
        timeline recovery-approval "$n"
      done
    fi
    sleep 15
  done
}

run_step() { # name function args...; the step runs in the background so errexit applies inside it
  local name=$1 pid rc=0
  shift
  timeline "${name}" "start $*"
  (
    STEP=${name}
    "$@"
  ) >"${STEPS}/${name}.log" 2>&1 &
  pid=$!
  wait "$pid" || rc=$?
  echo "$rc" >"${STEPS}/${name}.rc"
  [[ $rc == 0 || -s ${STEPS}/${name}.detail ]] || echo "exited ${rc}; see steps/${name}.log" >"${STEPS}/${name}.detail"
  timeline "${name}" "end rc=${rc}"
  sed "s/^/[${name}] /" "${STEPS}/${name}.log"
}

enable_toggle() {
  local before deadline
  count() { oc get events -A --field-selector "reason=${APPROVER_ENABLED_EVENT}" -o json | jq '[.items[] | (.count // 1)] | add // 0'; }
  before=$(count)
  # Recreate it so its creationTimestamp marks this run.
  oc delete configmap -n "${TOGGLE_NS}" "${TOGGLE_NAME}" --ignore-not-found >/dev/null
  oc create -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: ${TOGGLE_NS}
  name: ${TOGGLE_NAME}
data:
  enabled: "true"
EOF
  deadline=$(($(now) + $(dur "${APPROVER_EVENT_TIMEOUT}")))
  until (($(count) > before)); do
    (($(now) < deadline)) || die "no ${APPROVER_ENABLED_EVENT} Event within ${APPROVER_EVENT_TIMEOUT}: the KCMO image under test has no recovery approver"
    sleep 10
  done
  SINCE=$(oc get configmap -n "${TOGGLE_NS}" "${TOGGLE_NAME}" -o jsonpath='{.metadata.creationTimestamp}')
  timeline toggle-on "${SINCE}"
  log "approver enabled at ${SINCE}"
}

# --- steps ---
step_client_renew() { # submit a renewal CSR as the node, with its current client cert, as a kubelet does
  local node=$1 tmp name=normal-ops-renew-$1 server user
  tmp=$(mktemp -d)
  # Expanded now: the node's key must not outlive the step, and tmp is gone once the function returns.
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT
  debug_node "$node" 'cat /var/lib/kubelet/pki/kubelet-client-current.pem' >"${tmp}/current.pem" || fail "cannot read ${node}'s client cert"
  { openssl x509 -in "${tmp}/current.pem" -out "${tmp}/cert.pem" && openssl pkey -in "${tmp}/current.pem" -out "${tmp}/key.pem"; } ||
    fail "cannot split ${node}'s client cert and key"
  openssl ecparam -genkey -name prime256v1 -noout -out "${tmp}/new.key"
  openssl req -new -key "${tmp}/new.key" -subj "/O=system:nodes/CN=system:node:${node}" -out "${tmp}/req.pem"
  server=$(oc whoami --show-server)
  oc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d >"${tmp}/ca.crt"
  KUBECONFIG=${tmp}/kubeconfig oc config set-cluster c --server="${server}" --certificate-authority="${tmp}/ca.crt" --embed-certs >/dev/null
  KUBECONFIG=${tmp}/kubeconfig oc config set-credentials n --client-certificate="${tmp}/cert.pem" --client-key="${tmp}/key.pem" --embed-certs >/dev/null
  KUBECONFIG=${tmp}/kubeconfig oc config set-context n --cluster=c --user=n >/dev/null
  oc delete csr "${name}" --ignore-not-found >/dev/null
  KUBECONFIG=${tmp}/kubeconfig oc --context=n create -f - <<EOF || fail "${node} could not create a renewal CSR"
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${name}
spec:
  request: $(base64 -w0 "${tmp}/req.pem")
  signerName: ${SIGNER_CLIENT}
  usages: [digital signature, client auth]
EOF
  user=$(oc get csr "${name}" -o jsonpath='{.spec.username}')
  [[ $user == "system:node:${node}" ]] || fail "${name} was requested by ${user}, not system:node:${node}"
  decided() { [[ -n $(oc get csr "${name}" -o jsonpath='{.status.conditions[0].type}') ]]; }
  wait_for 120 "${name} approved or denied" decided || fail "${name} still pending after 2m"
  echo "${name}" >"${STEPS}/renewal-csr"
  log "${name}: $(oc get csr "${name}" -o jsonpath='{.status.conditions[0].type} {.status.conditions[0].reason}')"
}

step_scale_up() {
  local ms replicas before new
  ms=$(oc get machinesets -n "${MAPI_NS}" -o json | jq -r '[.items[] | select(.spec.replicas > 0) | .metadata.name] | sort | .[0] // empty')
  [[ -n $ms ]] || fail "no worker MachineSet with replicas > 0"
  replicas=$(oc get machineset -n "${MAPI_NS}" "${ms}" -o jsonpath='{.spec.replicas}')
  before=$(oc get nodes -o name | sort)
  log "scaling ${ms} ${replicas} -> $((replicas + 1))"
  oc scale machineset -n "${MAPI_NS}" "${ms}" --replicas=$((replicas + 1))
  new_node() { comm -13 <(echo "${before}") <(oc get nodes -o name | sort) | head -1 | sed 's|^node/||'; }
  has_new_node() { [[ -n $(new_node) ]]; }
  wait_for "$(dur "${NODE_TIMEOUT}")" "a new Node from ${ms}" has_new_node || fail "no new Node from ${ms} within ${NODE_TIMEOUT}"
  new=$(new_node)
  echo "${new}" >"${STEPS}/scale-up-node"
  wait_for "$(dur "${NODE_TIMEOUT}")" "${new} Ready" node_ready "${new}" || fail "${new} not Ready within ${NODE_TIMEOUT}"
}

step_serving_rotate() {
  local node=$1 before pod
  before=$(csr_json | jq -c --arg n "$node" --arg s "${SIGNER_SERVING}" '[.[] | select(.signer == $s and .node == $n) | .name]')
  move_aside_and_restart "$node" kubelet-server-current.pem || fail "cannot move ${node}'s serving cert aside"
  new_serving() {
    csr_json | jq -e --arg n "$node" --arg s "${SIGNER_SERVING}" --argjson b "$before" \
      'any(.[]; .signer == $s and .node == $n and .state == "Approved" and (.name | IN($b[]) | not))' >/dev/null
  }
  wait_for 900 "a new approved serving CSR for ${node}" new_serving || fail "no new approved serving CSR for ${node} within 15m"
  wait_for 600 "${node} Ready" node_ready "$node" || fail "${node} not Ready after the serving rotation"
  # kube-apiserver reaches the kubelet with the new serving cert.
  pod=$(oc get pods -A --field-selector "spec.nodeName=${node},status.phase=Running" -o jsonpath='{.items[0].metadata.namespace}/{.items[0].metadata.name}')
  logs_work() { oc logs -n "${pod%%/*}" "${pod##*/}" --all-containers --tail=1 >/dev/null 2>&1; }
  wait_for 300 "oc logs through ${node}'s kubelet (${pod})" logs_work || fail "oc logs through ${node}'s kubelet fails after the serving rotation"
}

step_stop_start() {
  local node=$1 id stopped_at
  id=$(aws ec2 describe-instances --output json --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    "Name=private-dns-name,Values=${node}" --query 'Reservations[].Instances[].InstanceId' | jq -r '.[0] // empty')
  [[ $id == i-* ]] || fail "no EC2 instance for ${node}"
  state_is() { [[ $(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text) == "$1" ]]; }
  log "stopping ${node} (${id}) for ${STOP_DURATION}"
  aws ec2 stop-instances --instance-ids "$id" >/dev/null
  wait_for 900 "${id} stopped" state_is stopped || fail "${id} did not stop within 15m"
  stopped_at=$(now)
  timeline stop-start "${node} stopped"
  while (($(now) < stopped_at + $(dur "${STOP_DURATION}"))); do sleep 30; done
  log "${node} Ready=$(oc get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') before the start"
  aws ec2 start-instances --instance-ids "$id" >/dev/null
  wait_for 600 "${id} running" state_is running || fail "${id} not running within 10m"
  timeline stop-start "${node} started after $(($(now) - stopped_at))s"
  wait_for "$(dur "${NODE_TIMEOUT}")" "${node} Ready again" node_ready "$node" || fail "${node} not Ready within ${NODE_TIMEOUT} of the start"
}

step_replace() {
  local node=$1 machine ms before new
  machine=$(oc get machines -n "${MAPI_NS}" -o json | jq -r --arg n "$node" '.items[] | select(.status.nodeRef.name == $n) | .metadata.name')
  [[ -n $machine ]] || fail "no Machine for ${node}"
  ms=$(oc get machine -n "${MAPI_NS}" "${machine}" -o jsonpath='{.metadata.labels.machine\.openshift\.io/cluster-api-machineset}')
  before=$(oc get machines -n "${MAPI_NS}" -o json | jq -c '[.items[].metadata.name]')
  log "deleting Machine ${machine} (${node}, MachineSet ${ms})"
  oc delete machine -n "${MAPI_NS}" "${machine}" --wait=false
  wait_for "$(dur "${NODE_TIMEOUT}")" "Node ${node} gone" node_gone "$node" || fail "Node ${node} still exists after ${NODE_TIMEOUT}"
  wait_for 300 "Lease ${node} gone" lease_gone "$node" || fail "Lease ${node} still exists 5m after its Node was deleted"
  new_node() {
    oc get machines -n "${MAPI_NS}" -l "machine.openshift.io/cluster-api-machineset=${ms}" -o json |
      jq -r --argjson b "${before}" '.items[] | select(.metadata.name | IN($b[]) | not) | .status.nodeRef.name // empty' | head -1
  }
  new_ready() { new=$(new_node) && [[ -n $new ]] && node_ready "$new"; }
  wait_for "$(dur "${NODE_TIMEOUT}")" "a replacement Node from ${ms} Ready" new_ready || fail "no replacement Node from ${ms} Ready within ${NODE_TIMEOUT}"
  new_node >"${STEPS}/replacement-node"
}

step_client_reset() {
  local node=$1 before
  before=$(csr_json | jq -c --arg c "${SIGNER_CLIENT}" '[.[] | select(.signer == $c) | .name]')
  echo "$before" >"${STEPS}/reset-before.json"
  move_aside_and_restart "$node" kubelet-client-current.pem || fail "cannot move ${node}'s client cert aside"
  approved() {
    csr_json | jq -e --arg n "$node" --arg c "${SIGNER_CLIENT}" --argjson b "$before" \
      'any(.[]; .signer == $c and .node == $n and .state == "Approved" and (.name | IN($b[]) | not))' >/dev/null
  }
  wait_for "$(dur "${CLIENT_RESET_TIMEOUT}")" "a new approved client CSR for ${node}" approved ||
    fail "no new client CSR for ${node} approved within ${CLIENT_RESET_TIMEOUT}"
  wait_for "$(dur "${NODE_TIMEOUT}")" "${node} Ready" node_ready "$node" || fail "${node} not Ready after re-bootstrapping"
}

# --- verdicts: jq over one input document, so they can be checked offline ---
# input: {since, now, csrs, events, nodes: {renewed, scale_up, replacement, rotated, stopped}, steps: {name: {rc, detail}}}
normal_ops_checks() {
  jq -c --arg c "${SIGNER_CLIENT}" --arg s "${SIGNER_SERVING}" --arg b "${BOOTSTRAPPER}" --arg r "${APPROVER_REASON}" \
    --arg ma "${MACHINE_APPROVER_REASON}" --arg ren "${RENEWAL_REASON}" '
    . as $in | [.csrs[] | select(.created >= $in.since)] as $new
    | def step($n): ($in.steps[$n] // {rc: "missing", detail: "did not run"});
      def ok($n; $extra): if step($n).rc != 0 then {pass: false, detail: step($n).detail}
        elif ($extra | length) > 0 then {pass: false, detail: ($extra | join("; "))} else {pass: true, detail: ""} end;
      def want($csr): if $csr.signer == $s then $ma elif $csr.username == $b then $ma else $ren end;
      def from($n): [$new[] | select(.node == $n)];
      def joined($n; $what): (from($n)) as $f
        | [if any($f[]; .signer == $c and .username == $b and .state == "Approved") then empty else "\($n) has no approved bootstrap client CSR (\($what))" end,
           if any($f[]; .signer == $s and .state == "Approved") then empty else "\($n) has no approved serving CSR (\($what))" end];
    {"no-recovery-approvals": ([$new[] | select(.reason == $r) | "\(.name) (\(.node)) approved by \($r)"]
        + [$in.events[] | select(.last >= $in.since) | "Event \(.reason) at \(.last): \(.message)"]
        | {pass: (length == 0), detail: join("; ")}),
     "all-approved-by-routine-approvers": ([$new[] | select(.state != "Pending" or (.created | fromdateiso8601) < $in.now - 120)
        | select(.reason != want(.)) | "\(.name) (\(.node), \(.username | sub("^system:serviceaccount:.*"; "node-bootstrapper"))) is \(.state) \(.reason // "") but should be approved \(want(.))"]
        | {pass: (length == 0), detail: join("; ")}),
     "client-renewal": ok("client-renew"; [$new[] | select(.name == "normal-ops-renew-\($in.nodes.renewed)")
        | if .username != "system:node:\($in.nodes.renewed)" then "\(.name) requested by \(.username)"
          elif .reason != $ren then "\(.name) is \(.state) \(.reason // "") instead of approved \($ren)" else empty end]),
     "scale-up": ok("scale-up"; joined($in.nodes.scale_up // ""; "scale-up")),
     "replacement": ok("replacement"; joined($in.nodes.replacement // ""; "replacement")),
     "serving-rotation": ok("serving-rotation"; []),
     "stop-start": ok("stop-start"; [from($in.nodes.stopped)[] | "\(.name) from the stopped node \(.node): its certs were valid, so it should make no CSR"])}'
}
# input: {csrs, before (client CSR names before the reset), node, steps}
client_reset_checks() {
  jq -c --arg c "${SIGNER_CLIENT}" --arg r "${APPROVER_REASON}" --argjson min "${RESET_MIN_DELAY_S}" '
    . as $in | [.csrs[] | select(.signer == $c and .node == $in.node and (.name | IN($in.before[]) | not))] as $new
    | ($in.steps["client-reset"] // {rc: "missing", detail: "did not run"}) as $st
    | [if $st.rc != 0 then $st.detail else empty end,
       if ($new | length) == 0 then "no new client CSR from \($in.node)" else empty end,
       ($new[] | if .state != "Approved" then "\(.name) is \(.state)"
         elif .reason != $r then "\(.name) approved by \(.reason), not \($r)"
         elif ((.approved_at | fromdateiso8601) - (.created | fromdateiso8601)) < $min
           then "\(.name) approved \((.approved_at | fromdateiso8601) - (.created | fromdateiso8601))s after creation, before the heartbeat was stale for 5m"
         else empty end)]
    | {"client-reset": {pass: (length == 0), detail: join("; ")}}'
}

junit() { # checks-json
  local esc='s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<testsuite name=\"node-cert-recovery-normal-ops\" tests=\"$(jq length <<<"$1")\" failures=\"$(jq '[.[] | select(.pass | not)] | length' <<<"$1")\">"
    jq -r 'to_entries[] | [.key, (.value.pass | tostring), .value.detail] | @tsv' <<<"$1" | while IFS=$'\t' read -r name pass detail; do
      echo "  <testcase classname=\"node-cert-recovery-normal-ops\" name=\"node-cert-recovery normal operation with the toggle on: ${name}\">"
      [[ $pass == true ]] || echo "    <failure message=\"$(sed "${esc}" <<<"${detail}")\"></failure>"
      echo "  </testcase>"
    done
    echo "</testsuite>"
  } >"${ARTIFACT_DIR}/junit_node_cert_recovery_normal_ops.xml"
}

steps_json() {
  local f n
  for f in "${STEPS}"/*.rc; do
    [[ -e $f ]] || continue
    n=$(basename "$f" .rc)
    jq -nc --arg n "$n" --argjson rc "$(cat "$f")" --arg d "$(cat "${STEPS}/${n}.detail" 2>/dev/null || true)" '{key: $n, value: {rc: $rc, detail: $d}}'
  done | jq -sc from_entries
}
file_or_empty() { cat "${STEPS}/$1" 2>/dev/null || true; }
retry() { # command...; rides out a brief API error before the verdict
  local i
  for i in 1 2 3 4; do
    "$@" && return 0
    sleep $((i * 10))
  done
  return 1
}

main() {
  if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
  fi
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  INFRA_ID=$(jq -r .infraID "${SHARED_DIR}/metadata.json")
  AWS_DEFAULT_REGION=$(jq -r .aws.region "${SHARED_DIR}/metadata.json")
  export AWS_DEFAULT_REGION
  [[ $(echo "${CLIENT_RESET}" | tr '[:upper:]' '[:lower:]') == true ]] && reset=true || reset=false
  mkdir -p "${STEPS}"
  printf 'utc\tevent\tdetail\n' >"${OUT}/timeline.tsv"

  local nodes masters workers pids=() checks input
  nodes=$(oc get nodes -o json)
  mapfile -t masters < <(jq -r '.items[] | select(.metadata.labels | has("node-role.kubernetes.io/master") or has("node-role.kubernetes.io/control-plane")) | .metadata.name' <<<"$nodes" | sort)
  mapfile -t workers < <(jq -r '.items[] | select(.metadata.labels | has("node-role.kubernetes.io/worker")) | select(.metadata.labels | has("node-role.kubernetes.io/master") | not) | .metadata.name' <<<"$nodes" | sort)
  ((${#masters[@]} >= 1 && ${#workers[@]} >= 2)) || die "need at least 1 master and 2 workers (have ${#masters[@]} and ${#workers[@]})"
  log "masters: ${masters[*]}; workers: ${workers[*]}"

  enable_toggle
  watch_csrs &
  watch_pid=$!
  trap 'kill ${watch_pid} 2>/dev/null || true' EXIT

  run_step client-renew step_client_renew "${workers[1]}"
  run_step scale-up step_scale_up &
  pids+=($!)
  run_step serving-rotation step_serving_rotate "${masters[0]}" &
  pids+=($!)
  run_step stop-start step_stop_start "${workers[0]}" &
  pids+=($!)
  wait "${pids[@]}" || true
  if [[ -s ${STEPS}/scale-up-node ]]; then
    run_step replacement step_replace "$(cat "${STEPS}/scale-up-node")"
  else
    echo 1 >"${STEPS}/replacement.rc"
    echo "skipped: the scale-up made no node to replace" >"${STEPS}/replacement.detail"
  fi

  input=$(jq -n --arg since "${SINCE}" --argjson now "$(now)" --argjson csrs "$(retry csr_json)" --argjson events "$(retry approval_events)" \
    --arg renewed "${workers[1]}" --arg up "$(file_or_empty scale-up-node)" --arg rep "$(file_or_empty replacement-node)" \
    --arg rot "${masters[0]}" --arg stop "${workers[0]}" --argjson steps "$(steps_json)" \
    '{since: $since, now: $now, csrs: $csrs, events: $events, steps: $steps,
      nodes: {renewed: $renewed, scale_up: $up, replacement: $rep, rotated: $rot, stopped: $stop}}')
  jq . <<<"$input" >"${OUT}/normal-ops-input.json"
  checks=$(normal_ops_checks <<<"$input")
  timeline verdict-normal-ops "$(jq -c 'map_values(.pass)' <<<"$checks")"

  if [[ $reset == true ]]; then
    run_step client-reset step_client_reset "${workers[1]}"
    input=$(jq -n --argjson csrs "$(retry csr_json)" --argjson before "$(file_or_empty reset-before.json | jq -sc '.[0] // []')" \
      --arg node "${workers[1]}" --argjson steps "$(steps_json)" '{csrs: $csrs, before: $before, node: $node, steps: $steps}')
    jq . <<<"$input" >"${OUT}/client-reset-input.json"
    checks=$(jq -c --argjson r "$(client_reset_checks <<<"$input")" '. + $r' <<<"$checks")
    timeline verdict-client-reset "$(jq -c '.["client-reset"].pass' <<<"$checks")"
  fi

  kill "${watch_pid}" 2>/dev/null || true
  csr_json | jq . >"${OUT}/csrs.json" || true
  jq -r '.[] | [.created, .name, .signer, .node, .username, .state, (.reason // ""), (.approved_at // "")] | @tsv' "${OUT}/csrs.json" | sort >"${OUT}/csrs.tsv" || true
  oc get events -n "${KCM_NS}" -o yaml >"${OUT}/events-${KCM_NS}.yaml" 2>/dev/null || true
  for p in $(oc get pods -n "${KCM_NS}" -l app=kube-controller-manager -o name 2>/dev/null); do
    oc logs -n "${KCM_NS}" "$p" -c kube-controller-manager-recovery-controller >"${OUT}/${p##*/}.recovery-controller.log" 2>&1 || true
  done
  oc logs -n "${MA_NS}" deploy/machine-approver -c machine-approver-controller >"${OUT}/machine-approver.log" 2>&1 || true

  jq -n --argjson checks "$checks" --arg since "${SINCE}" --argjson csrs "$(cat "${OUT}/csrs.json")" \
    --arg renewed "${workers[1]}" --arg up "$(file_or_empty scale-up-node)" --arg rep "$(file_or_empty replacement-node)" \
    --arg rot "${masters[0]}" --arg stop "${workers[0]}" --arg reset "$([[ $reset == true ]] && echo "${workers[1]}")" \
    '{pass: ([$checks[] | .pass] | all), checks: $checks, toggle_applied_at: $since,
      nodes: {renewed: $renewed, scale_up: $up, replacement: $rep, rotated: $rot, stopped: $stop, reset: $reset},
      approvals_by_signer_reason: ([$csrs[] | select(.created >= $since and .reason != null)] | group_by(.signer + "|" + .reason)
        | map({key: (.[0].signer + "|" + .[0].reason), value: length}) | from_entries)}' | tee "${OUT}/verdict.json"
  junit "$checks"
  if jq -e 'all(.[]; .pass)' <<<"$checks" >/dev/null; then
    log "PASS"
  else
    log "ERROR: failed checks: $(jq -r 'to_entries[] | select(.value.pass | not) | "\(.key): \(.value.detail)"' <<<"$checks")"
    exit 1
  fi
}

# NORMAL_OPS_LIB_ONLY=true only defines the functions, for checking the verdicts offline.
[[ ${NORMAL_OPS_LIB_ONLY:-false} == true ]] || main
