#!/bin/bash
# jq filters use $vars inside single quotes on purpose.
# shellcheck disable=SC2016
# Build-and-ship test, step 1 of 3: check the cluster is still inside its 24h install window,
# optionally enable the kubelet client CSR recovery approver, and arm a one-shot clock jump on every
# node for its next boot. Ported from the OCPSTRAT-1346 e2e harness (prep phase).
set -o nounset
set -o errexit
set -o pipefail

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/proxy-conf.sh"
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

readonly KCMO_NS=openshift-kube-controller-manager-operator
readonly MA_NS=openshift-cluster-machine-approver
readonly TOGGLE_NS=openshift-config
readonly TOGGLE_NAME=node-client-cert-recovery
readonly APPROVER_REASON=KCMRecoveryApprove
readonly APPROVER_ENABLED_EVENT=NodeCertRecoveryEnabled
readonly STATE="${SHARED_DIR}/build-and-ship-state.json"
readonly OUT="${ARTIFACT_DIR}/build-and-ship"
mkdir -p "${OUT}"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
die() {
  log "ERROR: $*"
  exit 1
}
now() { date -u +%s; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
dur() { # 30s 10m 6h 2d -> seconds
  local n=${1%[smhd]} u=${1: -1}
  [[ $n =~ ^[0-9]+$ ]] || die "invalid duration '$1'"
  case $u in
    s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
    *) echo "$1" ;;
  esac
}
state_set() { # jq-filter [jq args...]
  local f=$1
  shift
  jq -c "$@" "$f" "${STATE}" >"${STATE}.tmp"
  mv "${STATE}.tmp" "${STATE}"
}

# ns name -> {not_before, not_after} epochs, from the library-go annotations or else tls.crt.
secret_cert_window() {
  local raw w dates
  raw=$(oc get secret -n "$1" "$2" -o json) || return 1
  w=$(jq -c '(.metadata.annotations // {}) as $a
    | {not_before: ($a["auth.openshift.io/certificate-not-before"] // null | if . then fromdateiso8601 else null end),
       not_after: ($a["auth.openshift.io/certificate-not-after"] // null | if . then fromdateiso8601 else null end)}' <<<"$raw")
  if [[ $(jq -r .not_after <<<"$w") != null ]]; then
    echo "$w"
    return 0
  fi
  dates=$(jq -r '.data["tls.crt"]' <<<"$raw" | base64 -d | openssl x509 -noout -startdate -enddate)
  jq -nc --argjson nb "$(date -u -d "$(sed -n 's/^notBefore=//p' <<<"$dates")" +%s)" \
    --argjson na "$(date -u -d "$(sed -n 's/^notAfter=//p' <<<"$dates")" +%s)" '{not_before: $nb, not_after: $na}'
}

[[ ${NODE_CLIENT_CERT_RECOVERY_TOGGLE} == on || ${NODE_CLIENT_CERT_RECOVERY_TOGGLE} == off ]] || die "NODE_CLIENT_CERT_RECOVERY_TOGGLE must be 'on' or 'off' (got '${NODE_CLIENT_CERT_RECOVERY_TOGGLE}')"
skew_s=$(dur "${SKEW}")
echo '{}' >"${STATE}"
state_set '. + {toggle: $t, skew_seconds: $s}' --arg t "${NODE_CLIENT_CERT_RECOVERY_TOGGLE}" --argjson s "${skew_s}"

# --- window guard: the cluster must still be on its 24h install-time signer ---
signer=$(secret_cert_window "${KCMO_NS}" csr-signer-signer) || die "cannot read ${KCMO_NS}/csr-signer-signer"
csr_signer=$(secret_cert_window "${KCMO_NS}" csr-signer) || die "cannot read ${KCMO_NS}/csr-signer"
lifetime=$(jq '.not_after - .not_before' <<<"$signer")
remaining=$(($(jq .not_after <<<"$signer") - $(now)))
log "csr-signer-signer: lifetime ${lifetime}s, expires $(iso "$(jq .not_after <<<"$signer")") (in ${remaining}s)"
((lifetime <= 25 * 3600)) || die "csr-signer-signer lifetime is ${lifetime}s: the first rotation already happened, so this is not the build-and-ship window"
((remaining >= $(dur "${MIN_WINDOW_REMAINING}"))) || die "only ${remaining}s left before signer expiry (MIN_WINDOW_REMAINING=${MIN_WINDOW_REMAINING})"
((skew_s >= remaining + 3600)) || die "SKEW=${SKEW} is too small: the certs expire in ${remaining}s; need at least that + 1h"
state_set '. + {signer: $s, csr_signer_pre: $c}' --argjson s "$signer" --argjson c "$csr_signer"

# --- toggle: enable the approver, prove it runs (its Event) and that it idles on a healthy cluster ---
event_count() {
  oc get events -A --field-selector "reason=${APPROVER_ENABLED_EVENT}" -o json | jq '[.items[] | (.count // 1)] | add // 0'
}
if [[ ${NODE_CLIENT_CERT_RECOVERY_TOGGLE} == on ]]; then
  before=$(event_count)
  oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: ${TOGGLE_NS}
  name: ${TOGGLE_NAME}
data:
  enabled: "true"
EOF
  deadline=$(($(now) + $(dur "${APPROVER_EVENT_TIMEOUT}")))
  until (($(event_count) > before)); do
    (($(now) < deadline)) || die "no ${APPROVER_ENABLED_EVENT} Event within ${APPROVER_EVENT_TIMEOUT}: the KCMO image under test has no recovery approver"
    sleep 10
  done
  log "approver enabled (${APPROVER_ENABLED_EVENT} Event seen)"
  deadline=$(($(now) + $(dur "${APPROVER_IDLE_CHECK}")))
  while (($(now) < deadline)); do
    ours=$(oc get csr -o json | jq -c --arg r "${APPROVER_REASON}" \
      '[.items[] | select(any(.status.conditions[]?; .type == "Approved" and .reason == $r)) | .metadata.name]')
    [[ $ours == "[]" ]] || die "the approver approved CSRs on a healthy cluster: ${ours}"
    sleep 15
  done
  log "approver approved nothing for ${APPROVER_IDLE_CHECK} on the healthy cluster"
fi

# --- per node: record cert evidence, install the boot-time skew unit, mask chronyd ---
unit=$(base64 -w0 <<'EOF'
[Unit]
Description=e2e: jump clock forward before kubelet/crio start (OCPSTRAT-1346 build-and-ship test)
DefaultDependencies=no
After=local-fs.target
Before=kubelet-dependencies.target crio.service kubelet.service chrony-wait.service shutdown.target
Conflicts=shutdown.target
ConditionPathExists=/etc/e2e-clock-skew

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'date -u -s "@$(( $(date +%%s) + $(cat /etc/e2e-clock-skew) ))"'
ExecStartPost=/bin/rm -f /etc/e2e-clock-skew

[Install]
WantedBy=multi-user.target kubelet-dependencies.target
EOF
)
payload=$(base64 -w0 <<EOF
set -u
emit() { echo "E2E:\$1=\$2"; }
cert_end() { date -u -d "\$(openssl x509 -noout -enddate -in "\$1" | cut -d= -f2)" +%s; }
emit boot_id "\$(cat /proc/sys/kernel/random/boot_id)"
emit kubelet_client_not_after "\$(cert_end /var/lib/kubelet/pki/kubelet-client-current.pem)"
echo '${unit}' | base64 -d > /etc/systemd/system/e2e-clock-skew.service
echo '${skew_s}' > /etc/e2e-clock-skew
systemctl daemon-reload
systemctl enable e2e-clock-skew.service >/dev/null 2>&1
systemctl mask chronyd.service chrony-wait.service >/dev/null 2>&1
emit skew_unit "\$(systemctl is-enabled e2e-clock-skew.service 2>&1 || true)"
emit chronyd "\$(systemctl is-enabled chronyd.service 2>&1 || true)"
emit done ok
EOF
)

nodes=$(oc get nodes -o json | jq -c '[.items[] | {name: .metadata.name,
  role: (if (.metadata.labels | has("node-role.kubernetes.io/master") or has("node-role.kubernetes.io/control-plane")) then "master" else "worker" end),
  boot_id: .status.nodeInfo.bootID}]')
log "preparing $(jq length <<<"$nodes") nodes: $(jq -r 'map(.name) | join(" ")' <<<"$nodes")"
pids=()
# -n default: in a CI pod oc otherwise uses the pod's own namespace, which the cluster doesn't have.
for n in $(jq -r '.[].name' <<<"$nodes"); do
  timeout 300 oc debug "node/$n" -n default -q -- chroot /host bash -c "echo ${payload} | base64 -d | bash" \
    >"${OUT}/prep-$n.out" 2>"${OUT}/prep-$n.err" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || die "oc debug failed on a node (see ${OUT}/prep-*.err)"; done

problems=()
for n in $(jq -r '.[].name' <<<"$nodes"); do
  r=$(sed -n 's/^E2E://p' "${OUT}/prep-$n.out" | jq -Rn '[inputs | capture("^(?<key>[^=]+)=(?<value>.*)$")] | from_entries')
  [[ $(jq -r .done <<<"$r") == ok ]] || problems+=("$n: payload did not finish")
  [[ $(jq -r .skew_unit <<<"$r") == enabled ]] || problems+=("$n: skew unit not enabled")
  [[ $(jq -r .chronyd <<<"$r") == masked ]] || problems+=("$n: chronyd not masked")
  na=$(jq -r '.kubelet_client_not_after // "0"' <<<"$r")
  ((na > 0 && na < $(now) + skew_s)) || problems+=("$n: kubelet client cert (NotAfter ${na}) would still be valid after the skew")
  log "$n: kubelet client cert expires $(iso "${na:-0}")"
done
((${#problems[@]} == 0)) || die "prep checks failed: ${problems[*]}"

# Baseline for the assert step: CSRs and the machine-approver container that existed before the stop.
pre_csrs=$(oc get csr -o json | jq -c '[.items[].metadata.name]')
ma_started=$(oc get pods -n "${MA_NS}" -o json | jq -r '[.items[].status.containerStatuses[]? | select(.name == "machine-approver-controller") | .state.running.startedAt // empty][0] // ""')
state_set '. + {nodes: $n, pre_stop_csrs: $c, pre_stop_machine_approver_started_at: $m, prepared_at: $t}' \
  --argjson n "$nodes" --argjson c "$pre_csrs" --arg m "$ma_started" --argjson t "$(now)"
jq length <<<"$nodes" >"${SHARED_DIR}/build-and-ship-node-count"
cp "${STATE}" "${OUT}/state-after-prep.json"
log "prep done: window OK, toggle ${NODE_CLIENT_CERT_RECOVERY_TOGGLE}, skew ${SKEW} armed on every node"
