#!/bin/bash
#
# Azure API diagnostic observer for the Secrets Store CSI Driver Operator
# TLS groups rehearsal.
#
# ci-operator starts observers before the "pre" phase and terminates them
# (SIGTERM, then SIGKILL after grace_period) before the "post" phase, so this
# observer runs while the cluster is installed, while tls-groups-configure
# rolls out the TLS profile, and while the cluster API is unreachable.
#
# Every Azure call is a read-only Azure Resource Manager request made with the
# cluster profile identity that gather-azure-cli already uses, scoped to the
# job's own resource group. No call needs the cluster's Kubernetes API.
# It samples:
#   - load balancer health-probe (DipAvailability) and data-path
#     (VipAvailability) metrics for the API (6443) and machine config (22623)
#     ports, per control-plane backend,
#   - control-plane VM power and provisioning state,
#   - serial console line categories from boot diagnostics, counted in memory,
# plus anonymous (no credentials) TCP/TLS/HTTP reachability of the API
# endpoint.
#
# Public output (ARTIFACT_DIR and stdout) contains only allowlisted
# categories, counts, port numbers, ordinal labels (for example "master-0")
# and timestamps. Raw Azure responses, names, IDs, IP addresses, hostnames and
# serial console text stay in a private temporary directory that is deleted
# on exit. A final redaction guard withholds public detail if any known
# sensitive value or generic identifier pattern would be published.

# ci-operator runs commands as `bash -c "set -eu; <commands>"`. Sampling must
# survive individual failures, so errexit is turned off explicitly and every
# failure is handled and counted where it happens.
set -uo pipefail
set +o errexit
set +x
umask 077

SCHEMA="azure-api-diag/v1"
API_PORTS='[6443,22623]'
SHARED_MOUNT="${AZURE_API_DIAG_SHARED_MOUNT:-/var/run/secrets/ci.openshift.io/multi-stage}"

log() {
  # Only pass constant text, numbers and allowlisted categories.
  printf '%s azure-api-diag: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

iso_minus() {
  date -u -d "@$(( $(date -u +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ
}

bounded_int() {
  # bounded_int VALUE DEFAULT MIN MAX
  local value="$1" default="$2" min="$3" max="$4"
  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    value="${default}"
  fi
  if (( value < min )); then
    value="${min}"
  elif (( value > max )); then
    value="${max}"
  fi
  printf '%s' "${value}"
}

SAMPLE_INTERVAL="$(bounded_int "${AZURE_API_DIAG_SAMPLE_INTERVAL:-60}" 60 1 600)"
MAX_SAMPLES="$(bounded_int "${AZURE_API_DIAG_MAX_SAMPLES:-420}" 420 1 2000)"
# Stop sampling early enough for the final collection to finish before the
# observer timeout (7h).
MAX_DURATION="$(bounded_int "${AZURE_API_DIAG_MAX_DURATION:-24000}" 24000 60 86400)"
TARGET_WAIT="$(bounded_int "${AZURE_API_DIAG_TARGET_WAIT:-10800}" 10800 0 86400)"
BOOTLOG_EVERY="$(bounded_int "${AZURE_API_DIAG_BOOTLOG_EVERY:-10}" 10 1 1000)"
CALL_TIMEOUT="$(bounded_int "${AZURE_API_DIAG_CALL_TIMEOUT:-60}" 60 5 300)"
# Final collection budget, counted from SIGTERM. The in-flight call (up to
# 2 x CALL_TIMEOUT) plus this budget plus one overrunning call must stay
# below the observer grace_period (20m).
FINAL_BUDGET="$(bounded_int "${AZURE_API_DIAG_FINAL_BUDGET:-840}" 840 30 3600)"
PQC_GROUP="${TLS_GROUPS:-SecP384r1MLKEM1024}"
PQC_GROUP="${PQC_GROUP%%,*}"
if ! [[ "${PQC_GROUP}" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
  PQC_GROUP="SecP384r1MLKEM1024"
fi
CLASSICAL_GROUPS="X25519:P-256:P-384"

PUBLIC_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/azure-api-diag"
WORK_DIR=""
RECORDS=""
ERRORS=""
SENSITIVE=""
TERMINATING=0
TERM_EPOCH=0
FINAL_PHASE=0
FINAL_DEADLINE=0
SLEEP_PID=""
SAMPLE_LBS="[]"
SAMPLE_VMS="{}"
SAMPLE_API="{}"
START_EPOCH="$(date -u +%s)"
START_ISO="$(now_iso)"
TERMINATION_REASON="running"
TARGET_RESOLVED=false
IDENTITY_OK=false
AZ_READY=false
DISCOVERED=false
SEQ=0

CLIENT_ID=""
CLIENT_SECRET=""
TENANT_ID=""
SUBSCRIPTION_ID=""
INFRA_ID=""
RESOURCE_GROUP=""
API_ENDPOINT=""
API_HOST=""

on_signal() {
  TERMINATING=1
  if (( TERM_EPOCH == 0 )); then
    TERM_EPOCH="$(date -u +%s)"
  fi
  if [[ -n "${SLEEP_PID}" ]]; then
    kill "${SLEEP_PID}" 2>/dev/null || true
  fi
}

cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    if [[ "${AZ_READY}" == "true" ]]; then
      timeout -k 5 30 az logout >/dev/null 2>&1 || true
    fi
    rm -rf "${WORK_DIR}"
  fi
}

interruptible_sleep() {
  (( TERMINATING )) && return 0
  sleep "$1" &
  SLEEP_PID=$!
  wait "${SLEEP_PID}" 2>/dev/null || true
  SLEEP_PID=""
}

should_stop() {
  # During sampling, stop at the next call boundary after SIGTERM. During the
  # final collection, stop when its budget is spent.
  if (( FINAL_PHASE )); then
    (( $(date -u +%s) >= FINAL_DEADLINE ))
  else
    (( TERMINATING ))
  fi
}

elapsed() {
  echo $(( $(date -u +%s) - START_EPOCH ))
}

add_sensitive() {
  local value
  for value in "$@"; do
    # Ignore very short values so that common substrings cannot cause false
    # positives; every identifier collected here is longer than this.
    if [[ ${#value} -ge 6 ]]; then
      printf '%s\n' "${value}" >> "${SENSITIVE}"
    fi
  done
}

categorize_error() {
  # categorize_error RC STDERR_FILE -> allowlisted category
  local rc="$1" file="$2"
  if [[ "${rc}" == "124" || "${rc}" == "137" ]]; then
    echo timeout
  elif grep -qiE 'AuthorizationFailed|does not have authorization|Forbidden|\b403\b' "${file}" 2>/dev/null; then
    echo permission_denied
  elif grep -qiE 'AADSTS|invalid_client|ExpiredAuthenticationToken|InvalidAuthenticationToken|az login' "${file}" 2>/dev/null; then
    echo auth_failed
  elif grep -qiE 'ResourceGroupNotFound|ResourceNotFound|NotFound|could not be found|\b404\b' "${file}" 2>/dev/null; then
    echo not_found
  elif grep -qiE 'TooManyRequests|Throttl|\b429\b' "${file}" 2>/dev/null; then
    echo throttled
  elif grep -qiE 'Max retries exceeded|Connection (aborted|refused|reset)|Name or service not known|Temporary failure in name resolution|timed out' "${file}" 2>/dev/null; then
    echo network_error
  elif [[ "${rc}" == "127" ]]; then
    echo tool_missing
  else
    echo other
  fi
}

record_error() {
  # record_error OPERATION CATEGORY (both allowlisted constants)
  printf '%s\t%s\n' "$1" "$2" >> "${ERRORS}"
}

az_json() {
  # az_json OPERATION OUTFILE AZ_ARGS... ; raw output stays in WORK_DIR
  local op="$1" out="$2" rc
  shift 2
  timeout -k 10 "${CALL_TIMEOUT}" az "$@" --only-show-errors -o json >"${out}" 2>"${WORK_DIR}/az.err"
  rc=$?
  if (( rc != 0 )); then
    record_error "${op}" "$(categorize_error "${rc}" "${WORK_DIR}/az.err")"
  elif ! jq -e . "${out}" >/dev/null 2>&1; then
    record_error "${op}" invalid_response
    rc=65
  fi
  : > "${WORK_DIR}/az.err"
  return "${rc}"
}

emit() {
  # emit JSON_LINE ; appended to the private candidate list that is published
  # only after the redaction guard passes.
  printf '%s\n' "$1" >> "${RECORDS}"
}

load_identity() {
  local sp="${CLUSTER_PROFILE_DIR:-}/osServicePrincipal.json"
  if [[ ! -r "${sp}" ]]; then
    record_error identity unavailable
    return 1
  fi
  CLIENT_ID="$(jq -r '.clientId // empty' "${sp}" 2>/dev/null)"
  CLIENT_SECRET="$(jq -r '.clientSecret // empty' "${sp}" 2>/dev/null)"
  TENANT_ID="$(jq -r '.tenantId // empty' "${sp}" 2>/dev/null)"
  SUBSCRIPTION_ID="$(jq -r '.subscriptionId // empty' "${sp}" 2>/dev/null)"
  add_sensitive "${CLIENT_ID}" "${CLIENT_SECRET}" "${TENANT_ID}" "${SUBSCRIPTION_ID}"
  if [[ -z "${CLIENT_ID}" || -z "${CLIENT_SECRET}" || -z "${TENANT_ID}" || -z "${SUBSCRIPTION_ID}" ]]; then
    record_error identity incomplete
    return 1
  fi
  return 0
}

find_file() {
  # find_file NAME -> first readable copy in the step snapshot or live mount
  local name="$1" candidate
  for candidate in "${SHARED_DIR:-/nonexistent}/${name}" "${SHARED_MOUNT}/${name}"; do
    if [[ -s "${candidate}" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

resolve_target() {
  local metadata
  metadata="$(find_file metadata.json)" || return 1
  INFRA_ID="$(jq -r '.infraID // empty' "${metadata}" 2>/dev/null)"
  RESOURCE_GROUP="$(jq -r '.azure.resourceGroupName // empty' "${metadata}" 2>/dev/null)"
  if [[ -z "${RESOURCE_GROUP}" && -n "${INFRA_ID}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
  fi
  add_sensitive "${INFRA_ID}" "${RESOURCE_GROUP}" "$(jq -r '.clusterName // empty' "${metadata}" 2>/dev/null)" "$(jq -r '.clusterID // empty' "${metadata}" 2>/dev/null)"
  if ! [[ "${RESOURCE_GROUP}" =~ ^[A-Za-z0-9._()-]{1,90}$ ]]; then
    record_error resolve_target invalid_metadata
    RESOURCE_GROUP=""
    return 1
  fi
  return 0
}

resolve_api_endpoint() {
  local kubeconfig candidate server
  [[ -n "${API_ENDPOINT}" ]] && return 0
  for candidate in "${KUBECONFIG:-}" "$(find_file kubeconfig)" "$(find_file kubeconfig-minimal)"; do
    [[ -n "${candidate}" && -s "${candidate}" ]] || continue
    kubeconfig="${candidate}"
    break
  done
  [[ -n "${kubeconfig:-}" ]] || return 1
  server="$(sed -n 's#^[[:space:]]*server:[[:space:]]*https://\([^/[:space:]]*\).*#\1#p' "${kubeconfig}" | head -n 1)"
  if ! [[ "${server}" =~ ^[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?$ ]]; then
    return 1
  fi
  API_HOST="${server%%:*}"
  if [[ "${server}" == *:* ]]; then
    API_ENDPOINT="${server}"
  else
    API_ENDPOINT="${server}:443"
  fi
  add_sensitive "${API_HOST}" "${API_ENDPOINT}"
  return 0
}

wait_for_target() {
  local deadline=$(( START_EPOCH + TARGET_WAIT ))
  log "waiting for the job's cluster metadata"
  while (( ! TERMINATING )); do
    if resolve_target; then
      TARGET_RESOLVED=true
      log "cluster metadata found"
      return 0
    fi
    if (( $(date -u +%s) >= deadline )); then
      record_error resolve_target timeout
      return 1
    fi
    interruptible_sleep "${SAMPLE_INTERVAL}"
  done
  return 1
}

az_login() {
  local rc
  # The secret is only passed to the az process inside this pod, as the
  # existing gather-azure-cli step does; output is discarded because it
  # lists subscription and tenant identifiers.
  timeout -k 10 "${CALL_TIMEOUT}" az login --service-principal -u "${CLIENT_ID}" -p "${CLIENT_SECRET}" --tenant "${TENANT_ID}" --only-show-errors >/dev/null 2>"${WORK_DIR}/az.err"
  rc=$?
  if (( rc != 0 )); then
    record_error az_login "$(categorize_error "${rc}" "${WORK_DIR}/az.err")"
    : > "${WORK_DIR}/az.err"
    return 1
  fi
  : > "${WORK_DIR}/az.err"
  AZ_READY=true
  return 0
}

vm_label_filter='
  def vmlabel:
    if test("-master-[0-9]+$") then "master-" + capture("-master-(?<n>[0-9]+)$").n
    elif test("-bootstrap$") then "bootstrap"
    elif test("-worker-") then "worker"
    else "other" end;
'

discover() {
  local lbs="${WORK_DIR}/lbs.json" nics="${WORK_DIR}/nics.json" vms="${WORK_DIR}/vms.json"
  az_json discover_lb "${lbs}" network lb list --resource-group "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION_ID}" || return 1
  az_json discover_nic "${nics}" network nic list --resource-group "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION_ID}" || return 1
  az_json discover_vm "${vms}" vm list --resource-group "${RESOURCE_GROUP}" --subscription "${SUBSCRIPTION_ID}" || return 1

  # Private inventory: load balancers that carry API or machine config rules.
  jq --argjson ports "${API_PORTS}" '
    [ .[]
      | {
          id: (.id // ""),
          name: (.name // ""),
          public: ([(.frontendIPConfigurations // .frontendIpConfigurations // [])[]
                    | select((.publicIPAddress // .publicIpAddress) != null)] | length > 0),
          probes: [(.probes // [])[] | {name: (.name // ""), protocol: (.protocol // ""), port: (.port // null),
                    request_path: (.requestPath // ""), interval: (.intervalInSeconds // null),
                    count: (.numberOfProbes // null), threshold: (.probeThreshold // null)}],
          rules: [(.loadBalancingRules // [])[] | {frontend_port: (.frontendPort // null), backend_port: (.backendPort // null),
                   probe: ((.probe.id // "") | split("/") | last)}]
        }
      | select([.rules[] | .frontend_port as $p | $ports | index($p)] | map(select(. != null)) | length > 0)
    ]
    | sort_by(.public, .name)
    | (map(select(.public)) | to_entries | map(.value + {role: "public", idx: .key})) +
      (map(select(.public | not)) | to_entries | map(.value + {role: "internal", idx: .key}))
    | .[0:4]
  ' "${lbs}" > "${WORK_DIR}/inventory.json" 2>/dev/null || { record_error discover_lb invalid_response; return 1; }

  # Private backend IP -> ordinal label map, and control-plane VM list.
  jq -r "${vm_label_filter}"'
    [ .[] | ((.virtualMachine.id // "") | split("/") | last) as $vm
      | (.ipConfigurations // [])[] | (.privateIPAddress // .privateIpAddress // empty) as $ip
      | {key: $ip, value: (if $vm == "" then "other" else ($vm | vmlabel) end)} ]
    | from_entries
  ' "${nics}" > "${WORK_DIR}/ipmap.json" 2>/dev/null || { record_error discover_nic invalid_response; return 1; }
  jq -r '[.[] | .name // empty | select(test("-master-[0-9]+$"))] | sort | .[0:5] | .[]' "${vms}" > "${WORK_DIR}/masters.txt" 2>/dev/null || { record_error discover_vm invalid_response; return 1; }
  # Serial console reads are limited to VMs with managed boot diagnostics, so
  # that az never has to search the subscription's storage accounts.
  jq -r '[.[] | select((.name // "") | test("-master-[0-9]+$"))
          | select((.diagnosticsProfile.bootDiagnostics.enabled // false) == true
                   and ((.diagnosticsProfile.bootDiagnostics.storageUri // "") == "")) | .name] | sort | .[0:5] | .[]' \
    "${vms}" > "${WORK_DIR}/serial-masters.txt" 2>/dev/null || : > "${WORK_DIR}/serial-masters.txt"
  if (( $(wc -l < "${WORK_DIR}/serial-masters.txt") < $(wc -l < "${WORK_DIR}/masters.txt") )); then
    record_error serial_console skipped_not_managed_boot_diagnostics
  fi

  # Everything discovered is private; register it with the redaction guard.
  local value
  while IFS= read -r value; do
    add_sensitive "${value}"
  done < <(jq -r '.[] | .id, .name' "${WORK_DIR}/inventory.json"; jq -r 'keys[]' "${WORK_DIR}/ipmap.json"; cat "${WORK_DIR}/masters.txt"; jq -r '.. | strings | select(test("^/subscriptions/"))' "${lbs}" "${nics}" "${vms}" 2>/dev/null)

  # Public inventory: roles, ordinal indexes, probe and rule shapes only.
  emit "$(jq -c --arg t "$(now_iso)" '
    def protocol: if . == "Http" or . == "Https" or . == "Tcp" then . else "other" end;
    def path: if . == "" or . == "/readyz" or . == "/healthz" or . == "/livez" then . else "other" end;
    def num: if type == "number" then . else null end;
    { kind: "inventory", t: $t,
      lbs: [ .[] | . as $lb
        | { role, idx,
            probes: [ .probes | to_entries[] | {idx: .key, protocol: (.value.protocol | protocol), port: (.value.port | num),
                      request_path: (.value.request_path | path), interval: (.value.interval | num),
                      count: (.value.count | num), threshold: (.value.threshold | num)} ],
            rules: [ .rules[] | .probe as $p
                     | {frontend_port: (.frontend_port | num), backend_port: (.backend_port | num),
                        probe_idx: ([$lb.probes[].name] | index($p))} ] } ] }
  ' "${WORK_DIR}/inventory.json")"
  DISCOVERED=true
  log "discovered $(jq 'length' "${WORK_DIR}/inventory.json") API load balancers and $(wc -l < "${WORK_DIR}/masters.txt") control-plane VMs"
  return 0
}

metric_points_filter='
  [ .value[]? | .timeseries[]?
    | (reduce (.metadatavalues // [])[] as $m ({}; .[(($m.name.value // "") | ascii_downcase)] = ($m.value // ""))) as $d
    | ((if $metric == "DipAvailability" then $d.backendport else $d.frontendport end) // "" | tostring | tonumber? // null) as $port
    | select($port != null and ($ports | index($port)) != null)
    | (if $metric == "DipAvailability" then ($ipmap[($d.backendipaddress // "")] // "unmapped") else "frontend" end) as $backend
    | .data[]?
    | select((.timeStamp | type) == "string" and (.timeStamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}")))
    | {port: $port, backend: $backend, minute: (.timeStamp[0:16] + ":00Z"),
       avg: (if (.average | type) == "number" then (.average | round) else null end)} ]
  | group_by(.port)
  | map({port: .[0].port,
         points: (group_by(.minute) | map({minute: .[0].minute,
                  backends: (map({key: .backend, value: .avg}) | from_entries)}))})
'

lb_metric() {
  # lb_metric LB_JSON METRIC START END OUTFILE_POINTS
  local lb="$1" metric="$2" start="$3" end="$4" out="$5" raw="${WORK_DIR}/metric.json" id filter
  id="$(jq -r '.id' <<<"${lb}")"
  if [[ "${metric}" == "DipAvailability" ]]; then
    filter="BackendIPAddress eq '*' and BackendPort eq '*'"
  else
    filter="FrontendPort eq '*'"
  fi
  az_json "metric_${metric}" "${raw}" monitor metrics list --resource "${id}" --metrics "${metric}" \
    --aggregation Average --interval PT1M --start-time "${start}" --end-time "${end}" \
    --filter "${filter}" --subscription "${SUBSCRIPTION_ID}" || return 1
  jq -c --arg metric "${metric}" --argjson ports "${API_PORTS}" --slurpfile ipmap "${WORK_DIR}/ipmap.json" \
    "(\$ipmap[0]) as \$ipmap | ${metric_points_filter}" "${raw}" > "${out}" 2>/dev/null || { record_error "metric_${metric}" invalid_response; return 1; }
  : > "${raw}"
  return 0
}

sample_lbs() {
  # Latest minute with data per load balancer, metric and port -> SAMPLE_LBS.
  local start end lb metric points="${WORK_DIR}/points.json" next
  SAMPLE_LBS="[]"
  start="$(iso_minus 300)"
  end="$(now_iso)"
  while IFS= read -r lb; do
    for metric in DipAvailability VipAvailability; do
      should_stop && return 0
      lb_metric "${lb}" "${metric}" "${start}" "${end}" "${points}" || continue
      if next="$(jq -c --argjson lb "${lb}" --arg metric "${metric}" --argjson acc "${SAMPLE_LBS}" '
          $acc + [ .[] | {role: $lb.role, idx: $lb.idx, metric: $metric, port}
                   + ((.points | map(select([.backends[]] | any(. != null))) | last) // {minute: null, backends: {}}) ]
        ' "${points}" 2>/dev/null)"; then
        SAMPLE_LBS="${next}"
      else
        record_error "metric_${metric}" invalid_response
      fi
    done
  done < <(jq -c '.[]' "${WORK_DIR}/inventory.json")
}

sample_vms() {
  # Control-plane VM power and provisioning state -> SAMPLE_VMS.
  local name label out="${WORK_DIR}/iv.json" next
  SAMPLE_VMS="{}"
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    should_stop && return 0
    label="$(jq -rn --arg n "${name}" "${vm_label_filter}"' $n | vmlabel')"
    if az_json vm_instance_view "${out}" vm get-instance-view --resource-group "${RESOURCE_GROUP}" --name "${name}" \
        --subscription "${SUBSCRIPTION_ID}" --query "instanceView.statuses[].code"; then
      next="$(jq -c --arg l "${label}" --argjson acc "${SAMPLE_VMS}" '
        def state($prefix; $allowed):
          ([.[]? | strings | select(startswith($prefix)) | ltrimstr($prefix) | ascii_downcase] | first // "unknown")
          | . as $v | if ($allowed | index($v)) != null then $v else "other" end;
        $acc + {($l): {power: state("PowerState/"; ["running","stopped","deallocated","starting","stopping","deallocating","unknown"]),
                       provisioning: state("ProvisioningState/"; ["succeeded","failed","creating","updating","deleting","canceled","unknown"])}}
      ' "${out}" 2>/dev/null)" || { record_error vm_instance_view invalid_response; next=""; }
    else
      next=""
    fi
    if [[ -z "${next}" ]]; then
      next="$(jq -c --arg l "${label}" --argjson acc "${SAMPLE_VMS}" -n '$acc + {($l): {power: "unavailable", provisioning: "unavailable"}}')"
    fi
    SAMPLE_VMS="${next}"
    : > "${out}"
  done < "${WORK_DIR}/masters.txt"
}

probe_readyz() {
  local code rc
  if ! command -v curl >/dev/null 2>&1; then
    echo client_missing
    return
  fi
  code="$(curl -sk -o /dev/null --connect-timeout 5 --max-time 10 -w '%{http_code}' "https://${API_ENDPOINT}/readyz" 2>/dev/null)"
  rc=$?
  case "${rc}" in
    0) if [[ "${code}" =~ ^[0-9]{3}$ ]]; then echo "http_${code}"; else echo http_unknown; fi ;;
    6) echo dns_failure ;;
    7) echo connect_failed ;;
    28) echo timeout ;;
    35) echo tls_handshake_failed ;;
    52) echo empty_reply ;;
    56) echo recv_failed ;;
    *) echo curl_error_other ;;
  esac
}

probe_tls() {
  # probe_tls GROUPS -> category for a TLS 1.3 handshake offering only GROUPS
  local groups="$1" rc out="${WORK_DIR}/tls.out" err="${WORK_DIR}/tls.err" category
  if ! command -v openssl >/dev/null 2>&1; then
    echo client_missing
    return
  fi
  timeout -k 5 15 openssl s_client -connect "${API_ENDPOINT}" -servername "${API_HOST}" -tls1_3 -groups "${groups}" \
    </dev/null >"${out}" 2>"${err}"
  rc=$?
  if (( rc == 124 )); then
    category=timeout
  elif grep -qiE 'Error with command|Error setting|unknown group|Failed to set groups|SSL_CONF_cmd|invalid group' "${err}"; then
    category=client_unsupported
  elif (( rc == 0 )) && grep -qE 'New, TLSv1\.3|Protocol *: *TLSv1\.3' "${out}"; then
    category=handshake_ok
  elif grep -qiE 'connect:errno|Connection refused|connect error|Connection timed out|No route to host|gethostbyname|Name or service not known|BIO_connect' "${err}"; then
    category=tcp_failed
  elif grep -qiE 'handshake failure|alert|no shared|wrong version|unsupported|no suitable' "${err}"; then
    category=handshake_rejected
  else
    category=other
  fi
  : > "${out}"
  : > "${err}"
  echo "${category}"
}

sample_api() {
  # Anonymous API endpoint reachability -> SAMPLE_API. Runs in the main shell
  # so that the resolved endpoint is cached across samples.
  local readyz classical pqc
  if ! resolve_api_endpoint; then
    SAMPLE_API='{"readyz":"no_endpoint","tls_classical":"no_endpoint","tls_pqc":"no_endpoint"}'
    return 0
  fi
  readyz="$(probe_readyz)"
  classical="$(probe_tls "${CLASSICAL_GROUPS}")"
  pqc="$(probe_tls "${PQC_GROUP}")"
  SAMPLE_API="$(jq -cn --arg r "${readyz}" --arg c "${classical}" --arg p "${pqc}" '{readyz: $r, tls_classical: $c, tls_pqc: $p}')"
}

classify_serial() {
  # Reads raw serial console text on stdin and prints only category counts.
  # Text that az returns as a JSON string keeps its line breaks as literal
  # "\n" sequences, so those are split as well.
  awk '
    function classify(s) {
      lines++
      if (s ~ /Linux version [0-9]/) c["boot_banner"]++
      if (s ~ /Kernel panic/) c["kernel_panic"]++
      if (s ~ /[Oo]ut of memory|oom-kill|invoked oom-killer/) c["oom"]++
      if (s ~ /Call Trace:/) c["call_trace"]++
      if (s ~ /blocked for more than [0-9]+ seconds/) c["hung_task"]++
      if (s ~ /Failed to start|failed with result/) c["systemd_unit_failed"]++
      if (s ~ /reboot: Restarting system|Reached target.*Reboot|systemd-shutdown/) c["reboot"]++
      if (s ~ /EXT4-fs error|XFS .*(error|corrupt|Corruption)/) c["fs_error"]++
      if (s ~ /[Ll]ink is [Dd]own/) c["link_down"]++
    }
    BEGIN { split("boot_banner kernel_panic oom call_trace hung_task systemd_unit_failed reboot fs_error link_down", k, " "); for (i in k) c[k[i]] = 0 }
    { n = split($0, parts, /(\\r)?\\n/); for (i = 1; i <= n; i++) classify(parts[i]) }
    END { printf "{\"lines\":%d", lines; for (m in c) printf ",\"%s\":%d", m, c[m]; printf "}\n" }
  '
}

sample_serial() {
  local name label counts rc result="{}"
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    if should_stop; then
      record_error serial_console stopped
      break
    fi
    label="$(jq -rn --arg n "${name}" "${vm_label_filter}"' $n | vmlabel')"
    # Raw console text is streamed straight into the classifier and is never
    # written to disk. tsv output prints the text itself rather than a JSON
    # string.
    if counts="$(timeout -k 10 $(( CALL_TIMEOUT * 2 )) az vm boot-diagnostics get-boot-log --resource-group "${RESOURCE_GROUP}" \
        --name "${name}" --subscription "${SUBSCRIPTION_ID}" --only-show-errors -o tsv 2>"${WORK_DIR}/az.err" | classify_serial)"; then
      rc=0
    else
      rc=$?
    fi
    if (( rc != 0 )) || ! jq -e 'type == "object"' <<<"${counts}" >/dev/null 2>&1; then
      record_error serial_console "$(categorize_error "${rc}" "${WORK_DIR}/az.err")"
      counts='{"unavailable":true}'
    fi
    : > "${WORK_DIR}/az.err"
    result="$(jq -c --arg l "${label}" --argjson acc "${result}" --argjson c "${counts}" -n '$acc + {($l): $c}')"
  done < "${WORK_DIR}/serial-masters.txt"
  [[ "${result}" == "{}" ]] && return 0
  emit "$(jq -cn --arg t "$(now_iso)" --argjson s "${result}" '{kind: "serial_console", t: $t, vms: $s}')"
}

take_sample() {
  local t
  SEQ=$(( SEQ + 1 ))
  SAMPLE_LBS="[]"
  SAMPLE_VMS="{}"
  t="$(now_iso)"
  # Retry a failed login on the first sample and then every fifth sample.
  if [[ "${IDENTITY_OK}" == "true" && "${AZ_READY}" != "true" ]] && (( SEQ == 1 || SEQ % 5 == 0 )); then
    az_login || true
  fi
  if [[ "${AZ_READY}" == "true" && "${DISCOVERED}" != "true" ]]; then
    discover || true
  fi
  if [[ "${DISCOVERED}" == "true" ]]; then
    sample_lbs
    sample_vms
    if (( (SEQ - 1) % BOOTLOG_EVERY == 0 )); then
      sample_serial
    fi
  fi
  sample_api
  emit "$(jq -cn --argjson seq "${SEQ}" --arg t "${t}" --argjson lb "${SAMPLE_LBS}" --argjson vms "${SAMPLE_VMS}" --argjson api "${SAMPLE_API}" \
    '{kind: "sample", seq: $seq, t: $t, lb: $lb, vms: $vms, api: $api}')"
  log "sample ${SEQ}: api readyz=$(jq -r '.readyz' <<<"${SAMPLE_API}") tls_classical=$(jq -r '.tls_classical' <<<"${SAMPLE_API}") lb_series=$(jq 'length' <<<"${SAMPLE_LBS}") all_backends_down_series=$(jq '[.[] | select(.metric == "DipAvailability" and (.backends | length) > 0 and ([.backends[]] | all(. == 0)))] | length' <<<"${SAMPLE_LBS}")"
}

final_collection() {
  local base start end lb metric points="${WORK_DIR}/points.json" series="[]" name label cpu="[]" next
  [[ "${DISCOVERED}" == "true" ]] || return 0
  base="$(date -u +%s)"
  if (( TERM_EPOCH > 0 )); then
    base="${TERM_EPOCH}"
  fi
  FINAL_DEADLINE=$(( base + FINAL_BUDGET ))
  FINAL_PHASE=1
  log "final backfill of load balancer metrics for the whole observation window"
  start="$(date -u -d "@$(( START_EPOCH - 600 ))" +%Y-%m-%dT%H:%M:%SZ)"
  end="$(now_iso)"
  while IFS= read -r lb; do
    for metric in DipAvailability VipAvailability; do
      if should_stop; then
        record_error final_backfill budget_exhausted
        continue
      fi
      lb_metric "${lb}" "${metric}" "${start}" "${end}" "${points}" || continue
      if next="$(jq -c --argjson lb "${lb}" --arg metric "${metric}" --argjson acc "${series}" \
          '$acc + [ .[] | {role: $lb.role, idx: $lb.idx, metric: $metric, port, points} ]' "${points}" 2>/dev/null)"; then
        series="${next}"
      else
        record_error final_backfill invalid_response
      fi
    done
  done < <(jq -c '.[]' "${WORK_DIR}/inventory.json")
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    if should_stop; then
      record_error final_backfill budget_exhausted
      break
    fi
    label="$(jq -rn --arg n "${name}" "${vm_label_filter}"' $n | vmlabel')"
    if az_json metric_vm_cpu "${WORK_DIR}/cpu.json" monitor metrics list --resource "${name}" --resource-group "${RESOURCE_GROUP}" \
        --resource-type Microsoft.Compute/virtualMachines --metrics "Percentage CPU" --aggregation Average --interval PT1M \
        --start-time "${start}" --end-time "${end}" --subscription "${SUBSCRIPTION_ID}"; then
      if next="$(jq -c --arg l "${label}" --argjson acc "${cpu}" '
          $acc + [{vm: $l, points: [.value[]?.timeseries[]?.data[]?
                   | select((.timeStamp | type) == "string" and (.timeStamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}")))
                   | [(.timeStamp[0:16] + ":00Z"), (if (.average | type) == "number" then (.average | round) else null end)]]}]
        ' "${WORK_DIR}/cpu.json" 2>/dev/null)"; then
        cpu="${next}"
      else
        record_error metric_vm_cpu invalid_response
      fi
    fi
    : > "${WORK_DIR}/cpu.json"
  done < "${WORK_DIR}/masters.txt"
  emit "$(jq -cn --arg t "$(now_iso)" --arg ws "${start}" --argjson lb "${series}" --argjson cpu "${cpu}" \
    '{kind: "backfill", t: $t, window_start: $ws, lb: $lb, vm_cpu: $cpu}')"
  sample_serial
}

read_t0() {
  local marker value
  marker="$(find_file azure-api-diag-t0)" || return 0
  value="$(head -c 64 "${marker}" | tr -d '[:space:]')"
  if [[ "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    printf '%s' "${value}"
  fi
}

summary_filter='
  def series_stats:
    { role, idx, metric, port,
      minutes: (.points | length),
      minutes_all_up: ([.points[] | [.backends[]] | select(length > 0 and all(. != null and . >= 99))] | length),
      minutes_all_down: ([.points[] | [.backends[]] | select(length > 0 and all(. != null and . == 0))] | length),
      minutes_mixed: ([.points[] | [.backends[]]
                       | select(any(. != null) and (all(. != null and . >= 99) | not) and (all(. != null and . == 0) | not))] | length),
      minutes_any_down: ([.points[] | [.backends[]] | select(any(. != null and . == 0))] | length),
      first_any_down: ([.points[] | select([.backends[]] | any(. != null and . == 0)) | .minute] | first),
      minutes_no_data: ([.points[] | [.backends[]] | select(length == 0 or all(. == null))] | length),
      first_all_down: ([.points[] | select([.backends[]] | length > 0 and all(. != null and . == 0)) | .minute] | first),
      last_all_up: ([.points[] | select([.backends[]] | length > 0 and all(. != null and . >= 99)) | .minute] | last),
      backends: ([.points[] | .backends | keys[]] | unique) };
  def counts(f): (map(f) | group_by(.) | map({key: (.[0] | tostring), value: length}) | from_entries);
  def transitions(f): (reduce .[] as $s ([]; if (length == 0 or .[-1].value != ($s | f)) then . + [{t: $s.t, value: ($s | f)}] else . end)) | .[0:50];
  ($records | map(select(.kind == "sample"))) as $samples
  | ($records | map(select(.kind == "backfill")) | last) as $backfill
  | ($records | map(select(.kind == "inventory")) | last) as $inventory
  | ($records | map(select(.kind == "serial_console"))) as $serial
  | { schema: $meta.schema,
      started: $meta.started, ended: $meta.ended, termination_reason: $meta.reason,
      config: $meta.config,
      t0: $meta.t0,
      target_resolved: $meta.target_resolved, identity_loaded: $meta.identity, azure_login: $meta.az_ready, discovered: $meta.discovered,
      tools: $meta.tools,
      samples_taken: ($samples | length),
      first_sample: ($samples | first | .t // null), last_sample: ($samples | last | .t // null),
      samples_before_t0: (if $meta.t0 == null then null else ($samples | map(select(.t < $meta.t0)) | length) end),
      samples_at_or_after_t0: (if $meta.t0 == null then null else ($samples | map(select(.t >= $meta.t0)) | length) end),
      lb_inventory: ($inventory.lbs // null),
      lb_health_source: (if $backfill != null and ($backfill.lb | length) > 0 then "backfill" else "samples" end),
      lb_health: (if $backfill != null and ($backfill.lb | length) > 0
                  then [$backfill.lb[] | series_stats]
                  else [$samples | map(.lb[] | select(.minute != null)) | group_by([.role, .idx, .metric, .port])[]
                        | {role: .[0].role, idx: .[0].idx, metric: .[0].metric, port: .[0].port,
                           points: (map({minute, backends}) | reverse | unique_by(.minute))} | series_stats] end),
      api_probe: { readyz: ($samples | counts(.api.readyz)), tls_classical: ($samples | counts(.api.tls_classical)),
                   tls_pqc: ($samples | counts(.api.tls_pqc)),
                   readyz_transitions: ($samples | transitions(.api.readyz)),
                   tls_classical_transitions: ($samples | transitions(.api.tls_classical)) },
      vm_state_transitions: ($samples | map(select((.vms | length) > 0)) | transitions(.vms)),
      serial_console_first: ($serial | first // null),
      serial_console_last: ($serial | last // null),
      errors: ($errors | group_by(.op) | map({key: .[0].op, value: (group_by(.category) | map({key: .[0].category, value: length}) | from_entries)}) | from_entries) }
'

# Matched case-insensitively. Published values never contain dots, IPv6-style
# colon groups, GUIDs or URLs, so any of these means something leaked.
# Keep in sync with the pre-rollout step (hack/test_azure_api_diag.py checks).
GENERIC_PATTERNS='([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}|[0-9a-f]{0,4}::[0-9a-f]{0,4}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|/subscriptions/|resourcegroups|sig(=|%3d)|eyj[a-z0-9_-]{10,}|private key|https?://|[a-z0-9-]\.[a-z]{2,}'

leak_guard() {
  # leak_guard FILE... -> 0 only when no sensitive value or generic identifier
  # is present. grep errors (exit status 2) fail closed.
  local rc
  if [[ -s "${SENSITIVE}" ]]; then
    grep -F -q -f "${SENSITIVE}" -- "$@" 2>/dev/null
    rc=$?
    (( rc == 1 )) || return 1
  fi
  grep -i -E -q -- "${GENERIC_PATTERNS}" "$@" 2>/dev/null
  rc=$?
  (( rc == 1 )) || return 1
  return 0
}

publish() {
  local summary="${WORK_DIR}/summary.json" records_json="${WORK_DIR}/records.json" errors_json="${WORK_DIR}/errors.json" t0 tools
  t0="$(read_t0)"
  tools="$(jq -cn --arg az "$(command -v az >/dev/null 2>&1 && echo true || echo false)" \
    --arg curl "$(command -v curl >/dev/null 2>&1 && echo true || echo false)" \
    --arg openssl "$(command -v openssl >/dev/null 2>&1 && echo true || echo false)" \
    '{az: ($az == "true"), curl: ($curl == "true"), openssl: ($openssl == "true")}')"
  jq -s '.' "${RECORDS}" > "${records_json}" 2>/dev/null || echo '[]' > "${records_json}"
  jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {op: .[0], category: .[1]})' "${ERRORS}" > "${errors_json}" 2>/dev/null || echo '[]' > "${errors_json}"
  jq -n --slurpfile records "${records_json}" --slurpfile errors "${errors_json}" \
    --argjson meta "$(jq -cn --arg schema "${SCHEMA}" --arg started "${START_ISO}" --arg ended "$(now_iso)" \
      --arg reason "${TERMINATION_REASON}" --arg t0 "${t0}" --argjson tr "${TARGET_RESOLVED}" --argjson id "${IDENTITY_OK}" --argjson az "${AZ_READY}" \
      --argjson disc "${DISCOVERED}" --argjson tools "${tools}" \
      --argjson interval "${SAMPLE_INTERVAL}" --argjson max "${MAX_SAMPLES}" --argjson dur "${MAX_DURATION}" \
      '{schema: $schema, started: $started, ended: $ended, reason: $reason, t0: (if $t0 == "" then null else $t0 end),
        target_resolved: $tr, identity: $id, az_ready: $az, discovered: $disc, tools: $tools,
        config: {sample_interval_seconds: $interval, max_samples: $max, max_duration_seconds: $dur}}')" \
    "(\$records[0]) as \$records | (\$errors[0]) as \$errors | ${summary_filter}" > "${summary}" 2>/dev/null \
    || jq -cn --arg schema "${SCHEMA}" '{schema: $schema, summary_error: true}' > "${summary}"

  mkdir -p "${PUBLIC_DIR}"
  if leak_guard "${summary}" "${RECORDS}"; then
    cp "${RECORDS}" "${PUBLIC_DIR}/.samples.jsonl.tmp" && mv -f "${PUBLIC_DIR}/.samples.jsonl.tmp" "${PUBLIC_DIR}/samples.jsonl"
    cp "${summary}" "${PUBLIC_DIR}/.summary.json.tmp" && mv -f "${PUBLIC_DIR}/.summary.json.tmp" "${PUBLIC_DIR}/summary.json"
  else
    rm -f "${PUBLIC_DIR}/samples.jsonl"
    jq -cn --arg schema "${SCHEMA}" --arg reason "${TERMINATION_REASON}" --argjson n "$(wc -l < "${RECORDS}")" \
      '{schema: $schema, redaction_guard: "tripped", records_withheld: $n, termination_reason: $reason}' > "${PUBLIC_DIR}/summary.json"
    log "redaction guard tripped; public detail withheld"
  fi
}

setup() {
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/azure-api-diag.XXXXXX")" || exit 0
  chmod 700 "${WORK_DIR}"
  export AZURE_CONFIG_DIR="${WORK_DIR}/az-config"
  mkdir -p "${AZURE_CONFIG_DIR}"
  RECORDS="${WORK_DIR}/records.jsonl"
  ERRORS="${WORK_DIR}/errors.tsv"
  SENSITIVE="${WORK_DIR}/sensitive.txt"
  : > "${RECORDS}"
  : > "${ERRORS}"
  : > "${SENSITIVE}"
  mkdir -p "${PUBLIC_DIR}"
}

main() {
  trap on_signal TERM INT
  trap cleanup EXIT
  setup
  log "starting: interval=${SAMPLE_INTERVAL}s max_samples=${MAX_SAMPLES} max_duration=${MAX_DURATION}s"

  # Without the identity the observer still records anonymous API endpoint
  # reachability; the missing identity is reported in the error counts.
  if load_identity; then
    IDENTITY_OK=true
  fi
  if ! wait_for_target; then
    if (( TERMINATING )); then TERMINATION_REASON="sigterm"; else TERMINATION_REASON="target_unresolved"; fi
    publish
    log "finished: ${TERMINATION_REASON}"
    return 0
  fi

  while (( ! TERMINATING )); do
    if (( SEQ >= MAX_SAMPLES )); then
      TERMINATION_REASON="max_samples"
      break
    fi
    if (( $(elapsed) >= MAX_DURATION )); then
      TERMINATION_REASON="max_duration"
      break
    fi
    take_sample
    publish
    interruptible_sleep "${SAMPLE_INTERVAL}"
  done
  if (( TERMINATING )); then
    TERMINATION_REASON="sigterm"
  fi
  final_collection
  publish
  log "finished: ${TERMINATION_REASON} after ${SEQ} samples"
  return 0
}

# BASH_SOURCE is unset when ci-operator runs the commands with `bash -c`.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi
