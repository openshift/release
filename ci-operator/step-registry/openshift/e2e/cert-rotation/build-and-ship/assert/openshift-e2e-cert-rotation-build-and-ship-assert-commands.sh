#!/bin/bash
# jq filters use $vars inside single quotes on purpose.
# shellcheck disable=SC2016
# Build-and-ship test, step 3 of 3: after the power cycle, watch without approving anything and
# decide whether every node recovered unattended (NODE_CLIENT_CERT_RECOVERY_TOGGLE=on) or the gap reproduced (NODE_CLIENT_CERT_RECOVERY_TOGGLE=off).
# Ported from the OCPSTRAT-1346 e2e harness (observe phase).
set -o nounset
set -o errexit
set -o pipefail

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/proxy-conf.sh"
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# The cluster now runs ~SKEW ahead of this pod. Certificates it issues after the power-on (e.g. the
# kube-apiserver load-balancer serving cert, 12h on 5.1) are "not yet valid" for a client with a
# correct clock, so from here on, including the post steps, skip server-certificate verification.
# The admin client certificate still authenticates.
if grep -q 'certificate-authority-data:' "${KUBECONFIG}"; then
  cp "${KUBECONFIG}" "${SHARED_DIR}/kubeconfig.before-skew"
  sed -i -E 's/^([[:space:]]*)certificate-authority-data:.*/\1insecure-skip-tls-verify: true/' "${KUBECONFIG}"
fi

readonly SIGNER_CLIENT=kubernetes.io/kube-apiserver-client-kubelet
readonly SIGNER_SERVING=kubernetes.io/kubelet-serving
readonly BOOTSTRAPPER=system:serviceaccount:openshift-machine-config-operator:node-bootstrapper
readonly APPROVER_REASON=KCMRecoveryApprove
readonly MA_NS=openshift-cluster-machine-approver
readonly FRESH_S=300
readonly STATE="${SHARED_DIR}/build-and-ship-state.json"
readonly OUT="${ARTIFACT_DIR}/build-and-ship"
mkdir -p "${OUT}"
[[ -f ${STATE} ]] || { echo "missing ${STATE}: run the prep step first" >&2; exit 1; }

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
now() { date -u +%s; }
dur() {
  local n=${1%[smhd]}
  case ${1: -1} in s) echo "$n" ;; m) echo $((n * 60)) ;; h) echo $((n * 3600)) ;; d) echo $((n * 86400)) ;; *) echo "$1" ;; esac
}
timeline() { printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >>"${OUT}/timeline.tsv"; }

running_at=$(cat "${SHARED_DIR}/build-and-ship-running-at")
skew_s=$(jq .skew_seconds "${STATE}")
nodes=$(jq -c '[.nodes[].name]' "${STATE}")
masters=$(jq -c '[.nodes[] | select(.role == "master") | .name]' "${STATE}")
pre_csrs=$(jq -c .pre_stop_csrs "${STATE}")
ma_pre=$(jq -r .pre_stop_machine_approver_started_at "${STATE}")
printf 'utc\tevent\tdetail\n' >"${OUT}/timeline.tsv"

# --- cluster views (API only: kubelets can't serve logs or exec while unauthenticated) ---
cluster_now() { # newest kube-apiserver identity Lease renewal = the (skewed) cluster clock
  oc get lease -n kube-system -l apiserver.kubernetes.io/identity=kube-apiserver -o json 2>/dev/null |
    jq -r '[.items[].spec.renewTime // empty | sub("\\.[0-9]+"; "") | fromdateiso8601] | max // empty'
}
declare -A CN
csrs() { # CSRs created after the stop, with subject CN, approval reason and time
  local raw name req
  raw=$(oc get csr -o json 2>/dev/null) || return 1
  while IFS=$'\t' read -r name req; do
    [[ -n $name && -z ${CN[$name]:-} ]] || continue
    CN[$name]=$(base64 -d <<<"$req" | openssl req -noout -subject 2>/dev/null | sed -nE 's/.*CN ?= ?([^,/]+).*/\1/p' | sed -E 's/ +$//')
  done < <(jq -r --argjson pre "${pre_csrs}" '.items[] | select(.metadata.name | IN($pre[]) | not) | [.metadata.name, .spec.request] | @tsv' <<<"$raw")
  jq -c --argjson pre "${pre_csrs}" --argjson cn "$(for k in "${!CN[@]}"; do printf '%s\t%s\n' "$k" "${CN[$k]}"; done | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries')" '
    [.items[] | select(.metadata.name | IN($pre[]) | not)
     | ([.status.conditions[]? | select(.type == "Approved")][0] // null) as $a
     | {name: .metadata.name, signer: .spec.signerName, username: .spec.username,
        node: (($cn[.metadata.name] // "") | ltrimstr("system:node:")),
        reason: ($a.reason // null), approved_at: ($a.lastUpdateTime // null),
        state: (if any(.status.conditions[]?; .type == "Denied") then "Denied" elif $a then "Approved" else "Pending" end)}]' <<<"$raw"
}
node_view() { # now -> [{name, fresh}]; heartbeat age on the cluster clock
  oc get nodes -o json 2>/dev/null | jq -c --argjson now "$1" '[.items[]
    | ([.status.conditions[]? | select(.type == "Ready")][0]) as $r
    | {name: .metadata.name, ready: ($r.status // "Unknown"),
       fresh: ($r.status == "True" and (($now - ($r.lastHeartbeatTime | sub("\\.[0-9]+"; "") | fromdateiso8601)) < '"${FRESH_S}"'))}]'
}
ma_started() {
  oc get pods -n "${MA_NS}" -o json 2>/dev/null |
    jq -r '[.items[].status.containerStatuses[]? | select(.name == "machine-approver-controller") | .state.running.startedAt // empty][0] // ""'
}

# --- wait for the API ---
deadline=$(($(now) + $(dur "${API_TIMEOUT}")))
until oc get --raw /readyz >/dev/null 2>&1; do
  if (($(now) > deadline)); then
    log "ERROR: kube-apiserver not ready within ${API_TIMEOUT} after power-on"
    exit 1
  fi
  sleep 15
done
timeline api-up "$(($(now) - running_at))s after the machines were running"

# --- the skew must have happened ---
# Retry for up to 2 min; a failed read must not exit before the verdict and the manual fallback.
cnow=""
for _ in 1 2 3 4 5 6 7 8; do
  cnow=$(cluster_now) || true
  [[ -n $cnow ]] && break
  sleep 15
done
if [[ -n $cnow ]]; then
  offset=$((cnow - $(now)))
  clock_check=ok
  ((offset > skew_s - 600 && offset < skew_s + 600)) || clock_check=clock-skew-not-applied
  timeline clock-offset "${offset}s (expected ~${skew_s}s)"
  log "cluster clock offset ${offset}s (expected ~${skew_s}s)"
else
  offset=null
  clock_check=cluster-clock-unreadable
  timeline clock-offset "unknown: no kube-apiserver identity Lease readable"
  log "WARNING: cannot read the cluster clock from the kube-apiserver identity Leases"
fi

# --- watch, never approve ---
if [[ ${NODE_CLIENT_CERT_RECOVERY_TOGGLE} == on ]]; then window=$(dur "${RECOVERY_TIMEOUT}"); else window=$(dur "${GAP_WINDOW}"); fi
deadline=$(($(now) + window))
ma_restarted="" last="" C="[]" N="[]"
while (($(now) < deadline)); do
  cnow=$(cluster_now) || true
  C=$(csrs) || C="[]"
  [[ -n ${cnow} ]] && N=$(node_view "${cnow}" || echo "[]")
  s=$(ma_started) || s=""
  if [[ -z $ma_restarted && -n $s && $s != "${ma_pre}" ]]; then
    ma_restarted=$s
    timeline machine-approver-restarted "$s"
  fi
  line=$(jq -r --argjson n "$N" --arg c "${SIGNER_CLIENT}" --arg s "${SIGNER_SERVING}" '
    "client pending=\([.[] | select(.signer == $c and .state == "Pending")] | length) approved=\([.[] | select(.signer == $c and .state == "Approved")] | length)" +
    " serving pending=\([.[] | select(.signer == $s and .state == "Pending")] | length) approved=\([.[] | select(.signer == $s and .state == "Approved")] | length)" +
    " fresh=\([$n[] | select(.fresh)] | length)/\($n | length)"' <<<"$C")
  [[ $line == "$last" ]] || { timeline poll "$line"; log "$line"; last=$line; }
  if [[ ${NODE_CLIENT_CERT_RECOVERY_TOGGLE} == on ]] && jq -e --argjson want "${nodes}" --argjson n "$N" --arg s "${SIGNER_SERVING}" '
      ([$n[] | select(.fresh) | .name] | ($want - .) | length == 0) and
      ([.[] | select(.signer == $s and .state == "Approved") | .node] | ($want - .) | length == 0)' <<<"$C" >/dev/null; then
    timeline all-recovered "$(($(now) - running_at))s after the machines were running"
    break
  fi
  sleep 15
done
jq . <<<"$C" >"${OUT}/csrs.json"
jq . <<<"$N" >"${OUT}/nodes.json"
oc get events -n openshift-kube-controller-manager -o yaml >"${OUT}/events-openshift-kube-controller-manager.yaml" 2>/dev/null || true

# --- verdict ---
reasons=()
if [[ ${NODE_CLIENT_CERT_RECOVERY_TOGGLE} == on ]]; then
  verdict=RECOVERED_UNATTENDED
  f() { jq -c --argjson want "${nodes}" --argjson m "${masters}" --argjson n "$N" \
    --arg c "${SIGNER_CLIENT}" --arg s "${SIGNER_SERVING}" --arg r "${APPROVER_REASON}" "$1" <<<"$C"; }
  foreign=$(f '[.[] | select(.signer == $c and .reason != null and .reason != $r) | {name, node, reason}]')
  missing_ours=$(f '$want - [.[] | select(.signer == $c and .reason == $r) | .node]')
  not_fresh=$(f '$want - [$n[] | select(.fresh) | .name]')
  missing_serving=$(f '$want - [.[] | select(.signer == $s and .reason == "NodeCSRApprove") | .node]')
  first_master=$(f '[.[] | select(.signer == $c and .reason == $r and (.node | IN($m[]))) | .approved_at] | sort | .[0] // ""' | jq -r .)
  [[ $clock_check == ok ]] || reasons+=("${clock_check}")
  [[ $foreign == "[]" ]] || reasons+=("client-csrs-approved-by-something-else:${foreign}")
  [[ $missing_ours == "[]" ]] || reasons+=("nodes-without-an-approver-approval:${missing_ours}")
  [[ $not_fresh == "[]" ]] || reasons+=("nodes-not-ready-with-fresh-heartbeat:${not_fresh}")
  [[ $missing_serving == "[]" ]] || reasons+=("nodes-without-a-machine-approver-serving-approval:${missing_serving}")
  if [[ -n $first_master && -n $ma_restarted ]] &&
    (($(date -u -d "$first_master" +%s) >= $(date -u -d "$ma_restarted" +%s))); then
    reasons+=("machine-approver-restarted-before-the-first-master-approval")
  fi
  ((${#reasons[@]} == 0)) || verdict=NOT_RECOVERED_UNATTENDED
else
  verdict=GAP_REPRODUCED
  approved=$(jq -c --arg c "${SIGNER_CLIENT}" '[.[] | select(.signer == $c and .state == "Approved") | {name, node, reason}]' <<<"$C")
  without=$(jq -c --argjson want "${nodes}" --arg c "${SIGNER_CLIENT}" --arg u "${BOOTSTRAPPER}" \
    '$want - [.[] | select(.signer == $c and .username == $u) | .node]' <<<"$C")
  [[ $clock_check == ok ]] || reasons+=("${clock_check}")
  [[ $approved == "[]" ]] || reasons+=("client-csrs-approved-during-the-window:${approved}")
  [[ $without == "[]" ]] || reasons+=("nodes-without-a-bootstrap-client-csr:${without}")
  ((${#reasons[@]} == 0)) || verdict=GAP_NOT_REPRODUCED
fi
pass=false
[[ $verdict == RECOVERED_UNATTENDED || $verdict == GAP_REPRODUCED ]] && pass=true
jq -n --arg v "$verdict" --argjson pass "$pass" --arg toggle "${NODE_CLIENT_CERT_RECOVERY_TOGGLE}" --argjson offset "$offset" --argjson skew "$skew_s" \
  --argjson reasons "$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -sc 'map(select(length > 0))')" \
  --arg ma "$ma_restarted" --argjson by "$(jq -c 'map(select(.reason != null)) | group_by(.signer + "|" + .reason) | map({key: (.[0].signer + "|" + .[0].reason), value: length}) | from_entries' <<<"$C")" \
  '{verdict: $v, pass: $pass, toggle: $toggle, clock_offset_s: $offset, expected_offset_s: $skew, reasons: $reasons,
    machine_approver_restarted_at: (if $ma == "" then null else $ma end), approvals_by_signer_reason: $by}' |
  tee "${OUT}/verdict.json"
timeline verdict "$verdict ${reasons[*]:-}"

name="build-and-ship: nodes re-authenticate after the kubelet signer expired while powered off (toggle ${NODE_CLIENT_CERT_RECOVERY_TOGGLE})"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo "<testsuite name=\"cert-rotation-build-and-ship\" tests=\"1\" failures=\"$([[ $pass == true ]] && echo 0 || echo 1)\">"
  echo "  <testcase classname=\"cert-rotation-build-and-ship\" name=\"${name}\">"
  [[ $pass == true ]] || echo "    <failure message=\"${verdict}\">$(printf '%s\n' "${reasons[@]}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</failure>"
  echo "  </testcase>"
  echo "</testsuite>"
} >"${ARTIFACT_DIR}/junit_build_and_ship.xml"

# --- hand approval: the expected end of a toggle-off run, and the fallback after a failure, so the
# post steps can gather from a working cluster ---
if [[ $verdict != RECOVERED_UNATTENDED ]]; then
  log "approving pending kubelet CSRs by hand (toggle ${NODE_CLIENT_CERT_RECOVERY_TOGGLE}, verdict ${verdict})"
  deadline=$(($(now) + $(dur "${MANUAL_RECOVERY_TIMEOUT}")))
  while (($(now) < deadline)); do
    oc get csr -o json 2>/dev/null | jq -r --arg c "${SIGNER_CLIENT}" --arg s "${SIGNER_SERVING}" \
      '.items[] | select((.spec.signerName == $c or .spec.signerName == $s) and ((.status.conditions // []) | length == 0)) | .metadata.name' |
      xargs --no-run-if-empty oc adm certificate approve >/dev/null 2>&1 || true
    cnow=$(cluster_now) || true
    if [[ -n $cnow ]] && jq -e --argjson want "${nodes}" '$want - [.[] | select(.fresh) | .name] | length == 0' <<<"$(node_view "$cnow" || echo '[]')" >/dev/null; then
      timeline manual-recovery-done "every node fresh"
      break
    fi
    sleep 20
  done
fi

# Core operators only: with the clock SKEW ahead, operators that call the cloud API (cloud-credential,
# image-registry on AWS) stay degraded because the provider rejects requests signed with a skewed clock.
core="etcd kube-apiserver kube-controller-manager kube-scheduler openshift-apiserver authentication network dns machine-config"
deadline=$(($(now) + 1200))
until oc get co -o json 2>/dev/null | jq -e --arg core "$core" '($core | split(" ")) as $c
    | [.items[] | select(.metadata.name | IN($c[]))
       | select(any(.status.conditions[]?; (.type == "Available" and .status != "True") or (.type == "Degraded" and .status == "True")))]
    | length == 0' >/dev/null; do
  if (($(now) > deadline)); then
    log "WARNING: core operators not all Available and not Degraded 20m after recovery"
    break
  fi
  sleep 30
done
oc get co || true
[[ $pass == true ]] || { log "ERROR: verdict ${verdict}: ${reasons[*]}"; exit 1; }
log "PASS: ${verdict}"
