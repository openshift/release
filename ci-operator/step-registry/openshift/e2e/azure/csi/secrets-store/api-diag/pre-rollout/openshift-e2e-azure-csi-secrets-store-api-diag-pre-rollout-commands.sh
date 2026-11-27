#!/bin/bash
#
# Pre-rollout baseline and rollout boundary (T0) for the Azure API diagnostic
# rehearsal. Read-only against the cluster. Never fails, so that the TLS
# rollout step that follows always runs. Public output is limited to
# allowlisted enums, counts and timestamps.

# ci-operator runs commands as `bash -c "set -eu; <commands>"`; this step must
# never fail, so errexit is turned off explicitly.
set -uo pipefail
set +o errexit
set +x

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

OUT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/azure-api-diag"
mkdir -p "${OUT_DIR}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/azure-api-diag-pre.XXXXXX")"
chmod 700 "${WORK_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT

settle="${AZURE_API_DIAG_PRE_ROLLOUT_SETTLE:-300}"
if ! [[ "${settle}" =~ ^[0-9]+$ ]]; then
  settle=300
elif (( settle > 1800 )); then
  settle=1800
fi

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

log() {
  printf '%s azure-api-diag-pre-rollout: %s\n' "$(now_iso)" "$*"
}

# get_json NAME OC_GET_ARGS... -> WORK_DIR/NAME.json; prints an error category
get_json() {
  local name="$1" rc
  shift
  oc --request-timeout=20s get "$@" -o json >"${WORK_DIR}/${name}.json" 2>"${WORK_DIR}/err"
  rc=$?
  if (( rc == 0 )) && jq -e . "${WORK_DIR}/${name}.json" >/dev/null 2>&1; then
    echo ok
  elif grep -qiE 'i/o timeout|deadline exceeded|timed out|unable to return a response' "${WORK_DIR}/err"; then
    echo timeout
  elif grep -qiE 'connection refused|no route to host|connection reset|EOF' "${WORK_DIR}/err"; then
    echo connection_error
  elif grep -qiE 'Unauthorized|Forbidden|certificate' "${WORK_DIR}/err"; then
    echo auth_error
  elif grep -qiE 'NotFound|not found' "${WORK_DIR}/err"; then
    echo not_found
  else
    echo error
  fi
  : > "${WORK_DIR}/err"
}

json_or_null() {
  # json_or_null STATUS NAME JQ_FILTER
  if [[ "$1" == "ok" ]]; then
    jq -c "$3" "${WORK_DIR}/$2.json" 2>/dev/null || echo null
  else
    echo null
  fi
}

baseline_started="$(now_iso)"
log "recording pre-rollout baseline"

st_co="$(get_json co clusteroperator kube-apiserver)"
st_kas="$(get_json kas kubeapiserver cluster)"
st_fg="$(get_json fg featuregate cluster)"
st_apis="$(get_json apis apiserver cluster)"
st_nodes="$(get_json nodes nodes)"
st_cos="$(get_json cos clusteroperators)"

co_conditions="$(json_or_null "${st_co}" co '
  [.status.conditions[]? | select(.type == "Available" or .type == "Progressing" or .type == "Degraded")
   | {key: .type, value: (if .status == "True" or .status == "False" then .status else "Unknown" end)}] | from_entries')"
kas_revisions="$(json_or_null "${st_kas}" kas '
  (.status.latestAvailableRevision // 0) as $latest
  | {latest_available_revision: (if ($latest | type) == "number" then $latest else null end),
     nodes: ([.status.nodeStatuses[]?] | length),
     nodes_at_latest: ([.status.nodeStatuses[]? | select(.currentRevision == $latest)] | length),
     nodes_rolling: ([.status.nodeStatuses[]? | select((.targetRevision // 0) != 0 and .targetRevision != .currentRevision)] | length)}')"
feature_set="$(json_or_null "${st_fg}" fg '
  (.spec.featureSet // "") as $fs | if $fs == "" then "Default"
  elif (["TechPreviewNoUpgrade","CustomNoUpgrade","DevPreviewNoUpgrade","OKD"] | index($fs)) != null then $fs else "other" end')"
tls_profile="$(json_or_null "${st_apis}" apis '
  def allowed($list): . as $v | if ($list | index($v)) != null then $v else "other" end;
  {type: ((.spec.tlsSecurityProfile.type // "unset") | allowed(["unset","Old","Intermediate","Modern","Custom"])),
   adherence: ((.spec.tlsAdherence // "unset") | allowed(["unset","LegacyAdheringComponentsOnly","StrictAllComponents"])),
   custom_min_version: ((.spec.tlsSecurityProfile.custom.minTLSVersion // "unset")
                        | allowed(["unset","VersionTLS10","VersionTLS11","VersionTLS12","VersionTLS13"])),
   custom_groups: [(.spec.tlsSecurityProfile.custom.groups // [])[]
                   | allowed(["X25519","SecP256r1","SecP384r1","SecP521r1","X25519MLKEM768","SecP256r1MLKEM768","SecP384r1MLKEM1024"])]}')"
node_counts="$(json_or_null "${st_nodes}" nodes '
  def ready: ([.status.conditions[]? | select(.type == "Ready") | .status] | first) == "True";
  def cp: (.metadata.labels // {}) | has("node-role.kubernetes.io/master") or has("node-role.kubernetes.io/control-plane");
  {control_plane_ready: ([.items[] | select(cp and ready)] | length),
   control_plane_not_ready: ([.items[] | select(cp and (ready | not))] | length),
   other_ready: ([.items[] | select((cp | not) and ready)] | length),
   other_not_ready: ([.items[] | select((cp | not) and (ready | not))] | length)}')"
co_counts="$(json_or_null "${st_cos}" cos '
  def cond($t): [.status.conditions[]? | select(.type == $t) | .status] | first;
  {total: (.items | length),
   available: ([.items[] | select(cond("Available") == "True")] | length),
   progressing: ([.items[] | select(cond("Progressing") == "True")] | length),
   degraded: ([.items[] | select(cond("Degraded") == "True")] | length)}')"
baseline_ended="$(now_iso)"

log "baseline recorded; waiting ${settle}s so the observer collects pre-rollout samples"
sleep "${settle}"
t0="$(now_iso)"
printf '%s\n' "${t0}" > "${SHARED_DIR}/azure-api-diag-t0"

jq -n --arg started "${baseline_started}" --arg ended "${baseline_ended}" --arg t0 "${t0}" --argjson settle "${settle}" \
  --arg st_co "${st_co}" --arg st_kas "${st_kas}" --arg st_fg "${st_fg}" --arg st_apis "${st_apis}" \
  --arg st_nodes "${st_nodes}" --arg st_cos "${st_cos}" \
  --argjson co "${co_conditions}" --argjson kas "${kas_revisions}" --argjson fs "${feature_set}" \
  --argjson tls "${tls_profile}" --argjson nodes "${node_counts}" --argjson cos "${co_counts}" '
  {schema: "azure-api-diag-pre-rollout/v1", baseline_started: $started, baseline_ended: $ended,
   settle_seconds: $settle, t0: $t0,
   api_status: {kube_apiserver_operator: $st_co, kubeapiserver: $st_kas, featuregate: $st_fg,
                apiserver: $st_apis, nodes: $st_nodes, clusteroperators: $st_cos},
   kube_apiserver_conditions: $co, kube_apiserver_revisions: $kas, feature_set: $fs,
   tls_profile: $tls, nodes: $nodes, clusteroperators: $cos}' > "${WORK_DIR}/pre-rollout.json" 2>/dev/null \
  || printf '{"schema":"azure-api-diag-pre-rollout/v1","t0":"%s","summary_error":true}\n' "${t0}" > "${WORK_DIR}/pre-rollout.json"

# Every value above is an enum, count or timestamp; refuse to publish anything
# that looks like an address, identifier or URL. Same pattern as the observer
# (hack/test_azure_api_diag.py checks); grep errors fail closed.
GENERIC_PATTERNS='([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}|[0-9a-f]{0,4}::[0-9a-f]{0,4}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|/subscriptions/|resourcegroups|sig(=|%3d)|eyj[a-z0-9_-]{10,}|private key|https?://|[a-z0-9-]\.[a-z]{2,}'
grep -i -E -q -- "${GENERIC_PATTERNS}" "${WORK_DIR}/pre-rollout.json" 2>/dev/null
guard_rc=$?
if (( guard_rc != 1 )); then
  printf '{"schema":"azure-api-diag-pre-rollout/v1","t0":"%s","redaction_guard":"tripped"}\n' "${t0}" > "${OUT_DIR}/pre-rollout.json"
  log "redaction guard tripped; public detail withheld"
else
  cp "${WORK_DIR}/pre-rollout.json" "${OUT_DIR}/pre-rollout.json"
fi
log "rollout boundary T0=${t0}; API status: kube-apiserver-operator=${st_co} apiserver=${st_apis}"
exit 0
