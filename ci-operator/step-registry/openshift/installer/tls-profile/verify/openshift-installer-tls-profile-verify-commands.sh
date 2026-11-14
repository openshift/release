#!/bin/bash
#
# Verifies, without changing any cluster configuration, that a cluster created
# from an install-config.yaml with tlsProfileType=${INSTALL_CONFIG_TLS_PROFILE_TYPE}
# came up with that TLS security profile:
#
#   * the install-config.yaml handed to the installer requested the profile,
#   * APIServer/cluster carries the profile and tlsAdherence StrictAllComponents,
#   * the default IngressController reports the profile it inherits,
#   * the external API endpoint, every kube-apiserver instance and every etcd
#     member accept and reject TLS protocol versions and cipher suites the way
#     the profile, as implemented by the component serving the endpoint, defines.
#
# Expectations are derived from these public sources:
#   openshift/api            config/v1/types_tlssecurityprofile.go (TLSProfiles)
#   openshift/library-go     pkg/operator/configobserver/apiserver/observe_tlssecurityprofile.go
#   openshift/cluster-etcd-operator     pkg/etcdenvvar/etcd_env.go
#   openshift/cluster-ingress-operator  pkg/operator/controller/ingress/deployment.go
#
# A handshake counts as accepted only when the server answered the offered
# protocol version with a ServerHello. It counts as refused for the protocol
# version only when the server sent a protocol_version alert before any
# ServerHello, and as refused for the cipher suites only when it sent a
# handshake_failure or insufficient_security alert before any ServerHello; the
# kind of refusal must match the expectation. Client certificate or
# authentication failures that happen after the ServerHello therefore do not
# look like a refusal, and connection, client capability or unrecognized
# failures are reported as inconclusive and fail the step instead of being
# counted as a refusal.

set -o nounset
set -o errexit
set -o pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
VERIFY_ARTIFACT_DIR="${ARTIFACT_DIR}/tls-profile-verify"
# Timing settings; the offline test in hack/ shortens them.
PROBE_TIMEOUT_SECONDS="${PROBE_TIMEOUT_SECONDS:-20}"
PROBE_ATTEMPTS="${PROBE_ATTEMPTS:-3}"
PROBE_RETRY_DELAY_SECONDS="${PROBE_RETRY_DELAY_SECONDS:-5}"
INGRESS_STATUS_TIMEOUT_SECONDS="${INGRESS_STATUS_TIMEOUT_SECONDS:-600}"
STABLE_CLUSTER_TIMEOUT="${STABLE_CLUSTER_TIMEOUT:-30m}"
PORT_FORWARD_MAX_RESTARTS=5

# Handshakes probed against every endpoint. Each probe offers exactly one
# protocol version; the TLS 1.2 and older probes also offer a single cipher
# class in both ECDSA and RSA form so the result does not depend on the key
# type of the serving certificate.
PROBES=(tls13 tls12-aead tls12-cbc tls11-cbc tls10-cbc)

WORK_DIR=""
PROBE_OPENSSL_CONF=""
BACKGROUND_PIDS=()
RESULT_NAMES=()
RESULT_STATUSES=()
RESULT_MESSAGES=()
PORT_FORWARD_PID=""
PORT_FORWARD_LOCAL_PORT=""
PORT_FORWARD_STARTS=0
TEST_SERVER_PORT=""

log() {
  echo "$(date -u +%H:%M:%S) $*"
}

# --- Profile definitions ------------------------------------------------------

# Minimum TLS version of each predefined profile, from TLSProfiles in
# openshift/api config/v1/types_tlssecurityprofile.go
# (commit 2662c7aa27efb5ecde366840feb67de0916ac491).
profile_min_version() {
  case "$1" in
    Old) echo "VersionTLS10" ;;
    Intermediate) echo "VersionTLS12" ;;
    Modern) echo "VersionTLS13" ;;
    *) return 1 ;;
  esac
}

# Cipher list of each predefined profile, in OpenSSL names and in the order of
# TLSProfiles in the same openshift/api file and commit.
profile_ciphers() {
  local ciphers=()
  case "$1" in
    Old)
      ciphers=(
        TLS_AES_128_GCM_SHA256 TLS_AES_256_GCM_SHA384 TLS_CHACHA20_POLY1305_SHA256
        ECDHE-ECDSA-AES128-GCM-SHA256 ECDHE-RSA-AES128-GCM-SHA256
        ECDHE-ECDSA-AES256-GCM-SHA384 ECDHE-RSA-AES256-GCM-SHA384
        ECDHE-ECDSA-CHACHA20-POLY1305 ECDHE-RSA-CHACHA20-POLY1305
        ECDHE-ECDSA-AES128-SHA256 ECDHE-RSA-AES128-SHA256
        ECDHE-ECDSA-AES128-SHA ECDHE-RSA-AES128-SHA
        ECDHE-ECDSA-AES256-SHA384 ECDHE-RSA-AES256-SHA384
        ECDHE-ECDSA-AES256-SHA ECDHE-RSA-AES256-SHA
        AES128-GCM-SHA256 AES256-GCM-SHA384 AES128-SHA256 AES256-SHA256
        AES128-SHA AES256-SHA DES-CBC3-SHA
      )
      ;;
    Intermediate)
      ciphers=(
        TLS_AES_128_GCM_SHA256 TLS_AES_256_GCM_SHA384 TLS_CHACHA20_POLY1305_SHA256
        ECDHE-ECDSA-AES128-GCM-SHA256 ECDHE-RSA-AES128-GCM-SHA256
        ECDHE-ECDSA-AES256-GCM-SHA384 ECDHE-RSA-AES256-GCM-SHA384
        ECDHE-ECDSA-CHACHA20-POLY1305 ECDHE-RSA-CHACHA20-POLY1305
      )
      ;;
    Modern)
      ciphers=(TLS_AES_128_GCM_SHA256 TLS_AES_256_GCM_SHA384 TLS_CHACHA20_POLY1305_SHA256)
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${ciphers[@]}"
}

version_rank() {
  case "$1" in
    VersionTLS10) echo 10 ;;
    VersionTLS11) echo 11 ;;
    VersionTLS12) echo 12 ;;
    VersionTLS13) echo 13 ;;
    *) return 1 ;;
  esac
}

# Minimum TLS version a component enforces for a profile.
component_min_version() {
  local component="$1" profile="$2" min
  min="$(profile_min_version "${profile}")"
  case "${component}" in
    kube-apiserver)
      # library-go ObserveTLSSecurityProfile copies the profile minTLSVersion
      # into servingInfo.minTLSVersion unchanged.
      echo "${min}"
      ;;
    etcd)
      # cluster-etcd-operator getObservedTLSMinVersion passes TLS 1.3 through
      # and configures etcd with TLS1.2 for every other minimum, so Old and
      # Intermediate both start at TLS 1.2 on etcd.
      if [[ "${min}" == "VersionTLS13" ]]; then
        echo "VersionTLS13"
      else
        echo "VersionTLS12"
      fi
      ;;
    ingress)
      # The ingress operator raises TLS 1.0 to TLSv1.1 for the router and
      # reports VersionTLS11 in IngressController status.tlsProfile.
      if [[ "${min}" == "VersionTLS10" ]]; then
        echo "VersionTLS11"
      else
        echo "${min}"
      fi
      ;;
    *) return 1 ;;
  esac
}

# --- Probe catalog ------------------------------------------------------------

probe_version() {
  case "$1" in
    tls13) echo "VersionTLS13" ;;
    tls12-aead|tls12-cbc) echo "VersionTLS12" ;;
    tls11-cbc) echo "VersionTLS11" ;;
    tls10-cbc) echo "VersionTLS10" ;;
    *) return 1 ;;
  esac
}

# Protocol version as printed by "openssl s_client -msg".
probe_msg_label() {
  case "$(probe_version "$1")" in
    VersionTLS13) echo "1.3" ;;
    VersionTLS12) echo "1.2" ;;
    VersionTLS11) echo "1.1" ;;
    VersionTLS10) echo "1.0" ;;
  esac
}

probe_protocol_flag() {
  case "$(probe_version "$1")" in
    VersionTLS13) echo "-tls1_3" ;;
    VersionTLS12) echo "-tls1_2" ;;
    VersionTLS11) echo "-tls1_1" ;;
    VersionTLS10) echo "-tls1" ;;
  esac
}

# Cipher suites offered by the probe, colon separated. TLS 1.3 suites cannot be
# restricted in Go servers, so the TLS 1.3 probe offers the client defaults.
probe_ciphers() {
  case "$1" in
    tls13) echo "" ;;
    tls12-aead) echo "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256" ;;
    tls12-cbc|tls11-cbc|tls10-cbc) echo "ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA" ;;
    *) return 1 ;;
  esac
}

# Prints the expected result of a probe against a component configured with a
# profile: "accept", "reject-protocol" when the offered version is below the
# minimum the component enforces, or "reject-cipher" when the version is allowed
# but the profile does not list the offered cipher suites. Go servers check the
# version first, so a version below the minimum is refused with a
# protocol_version alert whatever the cipher suites. The cipher classes offered
# by the probes map to Go cipher suites that library-go and etcd both support,
# so membership in the profile decides.
expected_probe_result() {
  local component="$1" profile="$2" probe="$3"
  local min version ciphers cipher listed=0 total=0
  min="$(component_min_version "${component}" "${profile}")"
  version="$(probe_version "${probe}")"
  if (( $(version_rank "${version}") < $(version_rank "${min}") )); then
    echo "reject-protocol"
    return 0
  fi
  if [[ "${probe}" == "tls13" ]]; then
    if profile_ciphers "${profile}" | grep -qx "TLS_AES_128_GCM_SHA256"; then
      echo "accept"
      return 0
    fi
    echo "ERROR: profile ${profile} lists no TLS 1.3 cipher suite" >&2
    return 1
  fi
  ciphers="$(probe_ciphers "${probe}")"
  for cipher in ${ciphers//:/ }; do
    total=$((total + 1))
    if profile_ciphers "${profile}" | grep -qx -- "${cipher}"; then
      listed=$((listed + 1))
    fi
  done
  if (( listed == total )); then
    echo "accept"
  elif (( listed == 0 )); then
    echo "reject-cipher"
  else
    echo "ERROR: profile ${profile} lists only part of the ${probe} cipher class" >&2
    return 1
  fi
}

# --- Handshake probing ----------------------------------------------------------

# Classifies the output of one "openssl s_client -msg" run as ACCEPTED,
# REJECTED_PROTOCOL (protocol_version alert), REJECTED_CIPHER (handshake_failure
# or insufficient_security alert), CONNECT_ERROR, CLIENT_ERROR or INCONCLUSIVE.
#   $1: protocol version offered, as printed by -msg (for example 1.2)
#   $2: file holding the combined s_client output
#   $3: s_client exit code
classify_handshake() {
  local label="$1" output="$2" rc="$3"
  local server_hello='^<<< TLS 1\.[0-3], Handshake \[length [0-9a-fA-F]+\], ServerHello$'
  if grep -Eq "^<<< TLS ${label//./\\.}, Handshake \[length [0-9a-fA-F]+\], ServerHello$" "${output}"; then
    echo "ACCEPTED"
  elif grep -Eq "${server_hello}" "${output}"; then
    # A ServerHello for a version that was not offered is a broken exchange.
    echo "INCONCLUSIVE"
  elif [[ "${rc}" == "124" ]] || grep -Eq 'connect:errno=|BIO_connect|Connection refused|gethostbyname|getaddrinfo|BIO_lookup|Name or service not known|No route to host|Connection timed out' "${output}"; then
    echo "CONNECT_ERROR"
  elif grep -Eq 'no protocols available|no ciphers available|no cipher match|unsupported protocol|null ssl method|unknown option|Unknown option' "${output}"; then
    echo "CLIENT_ERROR"
  elif grep -Eq 'SSL alert number 70([^0-9]|$)' "${output}"; then
    echo "REJECTED_PROTOCOL"
  elif grep -Eq 'SSL alert number (40|71)([^0-9]|$)' "${output}"; then
    echo "REJECTED_CIPHER"
  else
    echo "INCONCLUSIVE"
  fi
}

# Runs one probe. Prints the classification; the raw output stays in $5.
run_probe_once() {
  local host="$1" port="$2" servername="$3" probe="$4" output="$5"
  local ciphers rc=0
  local args=(s_client -connect "${host}:${port}" -servername "${servername}" -msg "$(probe_protocol_flag "${probe}")")
  ciphers="$(probe_ciphers "${probe}")"
  if [[ -n "${ciphers}" ]]; then
    args+=(-cipher "${ciphers}:@SECLEVEL=0")
  fi
  OPENSSL_CONF="${PROBE_OPENSSL_CONF}" timeout "${PROBE_TIMEOUT_SECONDS}" openssl "${args[@]}" </dev/null >"${output}" 2>&1 || rc=$?
  classify_handshake "$(probe_msg_label "${probe}")" "${output}" "${rc}"
}

# Keeps the handshake messages, alerts and errors of an s_client run, without
# certificate subjects, so the transcript does not carry cluster host names.
sanitize_transcript() {
  grep -E '^(<<<|>>>) |SSL alert number|:error:|errno=|^New, |^issuer=' "$1" || true
}

issuer_common_name() {
  sed -n -E 's/^issuer=.*CN ?= ?([^,/]+).*$/\1/p' "$1" | head -n 1 | sed -E 's/[[:space:]]+$//'
}

write_probe_openssl_conf() {
  # A private OpenSSL configuration replaces the image crypto policy so the
  # client is able to offer TLS 1.0 and 1.1 and legacy cipher suites.
  PROBE_OPENSSL_CONF="${WORK_DIR}/openssl-probe.cnf"
  cat >"${PROBE_OPENSSL_CONF}" <<'EOF'
openssl_conf = openssl_init

[openssl_init]
ssl_conf = ssl_module

[ssl_module]
system_default = tls_system_default

[tls_system_default]
MinProtocol = TLSv1
CipherString = ALL:@SECLEVEL=0
EOF
}

# Starts a local openssl s_server and prints its port.
start_test_server() {
  local name="$1"
  shift
  local attempt port pid log_file i
  for ((attempt = 1; attempt <= 10; attempt++)); do
    port=$((20000 + RANDOM % 40000))
    log_file="${WORK_DIR}/server-${name}-${port}.log"
    OPENSSL_CONF="${PROBE_OPENSSL_CONF}" openssl s_server -accept "127.0.0.1:${port}" \
      -cert "${WORK_DIR}/self-test.crt" -key "${WORK_DIR}/self-test.key" -www "$@" >"${log_file}" 2>&1 &
    pid=$!
    for ((i = 0; i < 50; i++)); do
      if grep -q '^ACCEPT' "${log_file}"; then
        BACKGROUND_PIDS+=("${pid}")
        TEST_SERVER_PORT="${port}"
        return 0
      fi
      if ! kill -0 "${pid}" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  echo "ERROR: could not start local openssl s_server ${name}" >&2
  cat "${log_file}" >&2 || true
  return 1
}

# Proves, before any cluster endpoint is probed, that the probe client can
# offer every probed handshake and that the classification recognizes an
# accepted handshake, a protocol and a cipher rejection, a client certificate
# failure after an accepted handshake and an unreachable endpoint. Every
# command checks its own status because callers run this in a condition.
self_test_probe_client() {
  local failures=0 server port probe expected observed check closed_pid
  local any_port tls13_port aead_port client_cert_port closed_port
  local checks=()
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=tls-profile-verify-self-test" \
    -keyout "${WORK_DIR}/self-test.key" -out "${WORK_DIR}/self-test.crt" >/dev/null 2>&1 || return 1

  start_test_server any -cipher 'ALL:@SECLEVEL=0' || return 1
  any_port="${TEST_SERVER_PORT}"
  start_test_server tls13-only -tls1_3 || return 1
  tls13_port="${TEST_SERVER_PORT}"
  start_test_server tls12-aead-only -no_tls1_3 -cipher 'ECDHE-RSA-AES128-GCM-SHA256' || return 1
  aead_port="${TEST_SERVER_PORT}"
  start_test_server client-cert-required -Verify 1 -cipher 'ALL:@SECLEVEL=0' || return 1
  client_cert_port="${TEST_SERVER_PORT}"
  # The unreachable endpoint is the port of a server that was stopped again.
  start_test_server closed -cipher 'ALL:@SECLEVEL=0' || return 1
  closed_port="${TEST_SERVER_PORT}"
  closed_pid="${BACKGROUND_PIDS[${#BACKGROUND_PIDS[@]} - 1]}"
  kill "${closed_pid}" 2>/dev/null || true
  wait "${closed_pid}" 2>/dev/null || true

  for probe in "${PROBES[@]}"; do
    checks+=("any|${any_port}|${probe}|ACCEPTED")
  done
  checks+=(
    "tls13-only|${tls13_port}|tls13|ACCEPTED"
    "tls13-only|${tls13_port}|tls12-aead|REJECTED_PROTOCOL"
    "tls13-only|${tls13_port}|tls12-cbc|REJECTED_PROTOCOL"
    "tls13-only|${tls13_port}|tls11-cbc|REJECTED_PROTOCOL"
    "tls13-only|${tls13_port}|tls10-cbc|REJECTED_PROTOCOL"
    "tls12-aead-only|${aead_port}|tls12-aead|ACCEPTED"
    "tls12-aead-only|${aead_port}|tls12-cbc|REJECTED_CIPHER"
    "client-cert-required|${client_cert_port}|tls13|ACCEPTED"
    "client-cert-required|${client_cert_port}|tls12-aead|ACCEPTED"
    "closed|${closed_port}|tls12-aead|CONNECT_ERROR"
  )
  for check in "${checks[@]}"; do
    IFS='|' read -r server port probe expected <<<"${check}"
    observed="$(run_probe_once 127.0.0.1 "${port}" localhost "${probe}" "${WORK_DIR}/self-test.out")"
    if [[ "${observed}" == "${expected}" ]]; then
      log "self-test ${server} ${probe}: ${observed}"
    else
      log "self-test ${server} ${probe}: expected ${expected}, observed ${observed}"
      sanitize_transcript "${WORK_DIR}/self-test.out"
      failures=$((failures + 1))
    fi
  done
  return "${failures}"
}

# --- Result bookkeeping -------------------------------------------------------

record_result() {
  local name="$1" status="$2" message="$3"
  RESULT_NAMES+=("${name}")
  RESULT_STATUSES+=("${status}")
  RESULT_MESSAGES+=("${message}")
  if [[ "${status}" == "pass" ]]; then
    log "PASS: ${name}: ${message}"
  else
    log "FAIL: ${name}: ${message}"
  fi
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "${value}"
}

failure_count() {
  local status count=0
  for status in "${RESULT_STATUSES[@]+"${RESULT_STATUSES[@]}"}"; do
    if [[ "${status}" != "pass" ]]; then
      count=$((count + 1))
    fi
  done
  echo "${count}"
}

write_reports() {
  local i junit="${ARTIFACT_DIR}/junit_openshift_installer_tls_profile_verify.xml"
  local total="${#RESULT_NAMES[@]}" failures
  failures="$(failure_count)"
  mkdir -p "${VERIFY_ARTIFACT_DIR}"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<testsuite name=\"openshift-installer-tls-profile-verify\" tests=\"${total}\" failures=\"${failures}\">"
    for ((i = 0; i < total; i++)); do
      echo "  <testcase classname=\"openshift-installer-tls-profile-verify\" name=\"$(xml_escape "${RESULT_NAMES[i]}")\">"
      if [[ "${RESULT_STATUSES[i]}" != "pass" ]]; then
        echo "    <failure message=\"$(xml_escape "${RESULT_MESSAGES[i]}")\"></failure>"
      else
        echo "    <system-out>$(xml_escape "${RESULT_MESSAGES[i]}")</system-out>"
      fi
      echo "  </testcase>"
    done
    echo "</testsuite>"
  } >"${junit}"
  for ((i = 0; i < total; i++)); do
    printf '%-4s | %s | %s\n' "${RESULT_STATUSES[i]}" "${RESULT_NAMES[i]}" "${RESULT_MESSAGES[i]}"
  done >"${VERIFY_ARTIFACT_DIR}/summary.txt"
}

cleanup() {
  local status=$? pid
  trap - EXIT
  set +o errexit
  for pid in "${BACKGROUND_PIDS[@]+"${BACKGROUND_PIDS[@]}"}"; do
    kill "${pid}" 2>/dev/null
    wait "${pid}" 2>/dev/null
  done
  write_reports
  if [[ -n "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
  if (( status == 0 )) && (( $(failure_count) > 0 )); then
    status=1
  fi
  exit "${status}"
}

fatal() {
  record_result "$1" "fail" "$2"
  exit 1
}

# --- Cluster checks -------------------------------------------------------------

check_install_config() {
  local profile="$1" install_config="${SHARED_DIR}/install-config.yaml" values count
  if [[ ! -f "${install_config}" ]]; then
    fatal "install-config requested tlsProfileType" "${install_config} does not exist"
  fi
  # Read only the two top-level keys; the file also holds the pull secret.
  if grep -Eq '^fips:[[:space:]]*true[[:space:]]*$' "${install_config}"; then
    fatal "install-config requested tlsProfileType" "FIPS clusters filter profile ciphers and are not covered by this step"
  fi
  values="$(sed -n -E "s/^tlsProfileType:[[:space:]]*[\"']?([A-Za-z]*)[\"']?[[:space:]]*$/\1/p" "${install_config}")"
  count="$(grep -c '^tlsProfileType:' "${install_config}" || true)"
  if [[ "${count}" == "1" && "${values}" == "${profile}" ]]; then
    record_result "install-config requested tlsProfileType" "pass" "tlsProfileType ${profile} was set before installation"
  else
    record_result "install-config requested tlsProfileType" "fail" "expected one top-level tlsProfileType ${profile}, found ${count} entries (${values//$'\n'/,})"
  fi
}

check_apiserver_config() {
  local profile="$1" apiserver type adherence custom
  apiserver="$(oc get apiserver.config.openshift.io cluster -o json)"
  jq '{tlsSecurityProfile: .spec.tlsSecurityProfile, tlsAdherence: .spec.tlsAdherence,
       managedFields: [.metadata.managedFields[]? | {manager, operation, time}]}' \
    <<<"${apiserver}" >"${VERIFY_ARTIFACT_DIR}/apiserver.json"
  type="$(jq -r '.spec.tlsSecurityProfile.type // ""' <<<"${apiserver}")"
  adherence="$(jq -r '.spec.tlsAdherence // ""' <<<"${apiserver}")"
  custom="$(jq -r '.spec.tlsSecurityProfile.custom // empty' <<<"${apiserver}")"
  if [[ "${type}" == "${profile}" && -z "${custom}" ]]; then
    record_result "APIServer tlsSecurityProfile" "pass" "type is ${type}"
  else
    record_result "APIServer tlsSecurityProfile" "fail" "expected type ${profile} without a custom profile, found type '${type}'"
  fi
  if [[ "${adherence}" == "StrictAllComponents" ]]; then
    record_result "APIServer tlsAdherence" "pass" "tlsAdherence is StrictAllComponents"
  else
    record_result "APIServer tlsAdherence" "fail" "expected StrictAllComponents, found '${adherence}'"
    oc get featuregate cluster -o json | jq -c '[.status.featureGates[]? | {version, tlsAdherenceEnabled: ([.enabled[]?.name] | index("TLSAdherence") != null)}]' || true
  fi
}

check_ingress_profile() {
  local profile="$1" expected_min expected_ciphers status_json min ciphers deadline spec_type
  expected_min="$(component_min_version ingress "${profile}")"
  expected_ciphers="$(profile_ciphers "${profile}" | sort)"
  deadline=$(($(date +%s) + INGRESS_STATUS_TIMEOUT_SECONDS))
  while true; do
    status_json="$(oc get ingresscontroller.operator.openshift.io default -n openshift-ingress-operator -o json | jq -c '{spec: .spec.tlsSecurityProfile, status: .status.tlsProfile}')" || status_json='{"unreadable": true}'
    min="$(jq -r '.status.minTLSVersion // ""' <<<"${status_json}")"
    ciphers="$(jq -r '.status.ciphers // [] | .[]' <<<"${status_json}" | sort)"
    if [[ "${min}" == "${expected_min}" && "${ciphers}" == "${expected_ciphers}" ]]; then
      break
    fi
    if (( $(date +%s) >= deadline )); then
      break
    fi
    sleep 15
  done
  jq . <<<"${status_json}" >"${VERIFY_ARTIFACT_DIR}/ingresscontroller-default.json" || true
  # The installer no longer sets a profile on the default IngressController, so
  # it inherits the cluster profile. As in the ingress operator, an unset
  # profile or one with an empty type means the cluster profile applies.
  spec_type="$(jq -r '.spec.type // ""' <<<"${status_json}")"
  if [[ "$(jq -r '.unreadable // false' <<<"${status_json}")" == "true" ]]; then
    record_result "IngressController default inherits the cluster TLS profile" "fail" "the IngressController could not be read"
  elif [[ -z "${spec_type}" ]]; then
    record_result "IngressController default inherits the cluster TLS profile" "pass" "spec.tlsSecurityProfile does not select a profile"
  else
    record_result "IngressController default inherits the cluster TLS profile" "fail" "spec.tlsSecurityProfile selects '${spec_type}' instead of inheriting the cluster profile"
  fi
  if [[ "${min}" == "${expected_min}" ]]; then
    record_result "IngressController default status.tlsProfile minTLSVersion" "pass" "minTLSVersion is ${min}"
  else
    record_result "IngressController default status.tlsProfile minTLSVersion" "fail" "expected ${expected_min}, found '${min}'"
  fi
  if [[ "${ciphers}" == "${expected_ciphers}" ]]; then
    record_result "IngressController default status.tlsProfile ciphers" "pass" "ciphers match the ${profile} profile"
  else
    record_result "IngressController default status.tlsProfile ciphers" "fail" \
      "expected the ${profile} profile ciphers, missing [$(comm -23 <(echo "${expected_ciphers}") <(echo "${ciphers}") | paste -sd, -)], unexpected [$(comm -13 <(echo "${expected_ciphers}") <(echo "${ciphers}") | paste -sd, -)]"
  fi
}

save_observed_config() {
  # Diagnostics only: the TLS settings the operators derived. Only the TLS
  # fields are kept; servingInfo can also list named certificate host names.
  local filter='.spec.observedConfig.servingInfo // {} | {minTLSVersion, cipherSuites, groups}'
  oc get kubeapiserver.operator.openshift.io cluster -o json \
    | jq "${filter}" >"${VERIFY_ARTIFACT_DIR}/kube-apiserver-observed-tls.json" || true
  oc get etcd.operator.openshift.io cluster -o json \
    | jq "${filter}" >"${VERIFY_ARTIFACT_DIR}/etcd-observed-tls.json" || true
}

# Probes one endpoint with every probe and records a result per probe. Results
# other than an accepted or rejected handshake are retried.
#   $1 component (kube-apiserver or etcd)  $2 label  $3 host  $4 port
#   $5 TLS server name  $6 extended regex the serving certificate issuer CN must match
#   $7 $8 $9 optional namespace, pod and pod port of the port-forward that
#            provides host:port; it is restarted when it has exited
verify_endpoint() {
  local component="$1" label="$2" host="$3" port="$4" servername="$5" issuer_pattern="$6"
  local forward_namespace="${7:-}" forward_pod="${8:-}" forward_port="${9:-}"
  local profile="${INSTALL_CONFIG_TLS_PROFILE_TYPE}" probe expected observed output issuer name attempt
  output="${WORK_DIR}/probe.out"
  for probe in "${PROBES[@]}"; do
    expected="$(expected_probe_result "${component}" "${profile}" "${probe}")"
    observed=""
    for ((attempt = 1; attempt <= PROBE_ATTEMPTS; attempt++)); do
      : >"${output}"
      if [[ -n "${forward_pod}" ]]; then
        if ensure_port_forward "${forward_namespace}" "${forward_pod}" "${forward_port}"; then
          port="${PORT_FORWARD_LOCAL_PORT}"
          observed="$(run_probe_once "${host}" "${port}" "${servername}" "${probe}" "${output}")"
        else
          observed="PORT_FORWARD_ERROR"
        fi
      else
        observed="$(run_probe_once "${host}" "${port}" "${servername}" "${probe}" "${output}")"
      fi
      case "${observed}" in
        ACCEPTED|REJECTED_PROTOCOL|REJECTED_CIPHER) break ;;
      esac
      if (( attempt < PROBE_ATTEMPTS )); then
        sleep "${PROBE_RETRY_DELAY_SECONDS}"
      fi
    done
    {
      echo "### ${label} ${probe}: expected ${expected}, observed ${observed}"
      sanitize_transcript "${output}"
    } >>"${VERIFY_ARTIFACT_DIR}/handshakes.log"
    case "${expected}" in
      accept) name="${label} ${probe} handshake is accepted" ;;
      reject-protocol) name="${label} ${probe} handshake is rejected (protocol version)" ;;
      reject-cipher) name="${label} ${probe} handshake is rejected (cipher suite)" ;;
    esac
    case "${expected}:${observed}" in
      accept:ACCEPTED|reject-protocol:REJECTED_PROTOCOL|reject-cipher:REJECTED_CIPHER)
        record_result "${name}" "pass" "observed ${observed}"
        ;;
      accept:REJECTED_PROTOCOL|accept:REJECTED_CIPHER)
        record_result "${name}" "fail" "the endpoint rejected (${observed}) a handshake the ${profile} profile allows"
        ;;
      reject-*:ACCEPTED)
        record_result "${name}" "fail" "the endpoint accepted a handshake the ${profile} profile forbids"
        ;;
      reject-protocol:REJECTED_CIPHER)
        record_result "${name}" "fail" "the endpoint refused the cipher suites, not the protocol version, so it does not enforce the ${profile} minimum TLS version"
        ;;
      reject-cipher:REJECTED_PROTOCOL)
        record_result "${name}" "fail" "the endpoint refused the protocol version, so its minimum TLS version is above the ${profile} minimum"
        ;;
      *)
        record_result "${name}" "fail" "inconclusive result ${observed} after ${PROBE_ATTEMPTS} attempts; see handshakes.log"
        ;;
    esac
    if [[ "${probe}" == "tls13" && "${observed}" == "ACCEPTED" ]]; then
      issuer="$(issuer_common_name "${output}")"
      if [[ "${issuer}" =~ ${issuer_pattern} ]]; then
        record_result "${label} serves a ${component} certificate" "pass" "issuer CN ${issuer}"
      else
        record_result "${label} serves a ${component} certificate" "fail" "issuer CN '${issuer}' does not match ${issuer_pattern}"
      fi
    fi
  done
}

start_port_forward() {
  local namespace="$1" pod="$2" remote_port="$3" log_file="$4" i
  PORT_FORWARD_LOCAL_PORT=""
  oc -n "${namespace}" port-forward "pod/${pod}" ":${remote_port}" >"${log_file}" 2>&1 &
  PORT_FORWARD_PID=$!
  BACKGROUND_PIDS+=("${PORT_FORWARD_PID}")
  for ((i = 0; i < 60; i++)); do
    PORT_FORWARD_LOCAL_PORT="$(sed -n -E 's/^Forwarding from 127\.0\.0\.1:([0-9]+) -> .*$/\1/p' "${log_file}" | head -n 1)"
    if [[ -n "${PORT_FORWARD_LOCAL_PORT}" ]]; then
      return 0
    fi
    if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
      break
    fi
    sleep 0.5
  done
  return 1
}

stop_port_forward() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
  PORT_FORWARD_PID=""
  PORT_FORWARD_LOCAL_PORT=""
}

# Starts the port-forward to a pod, or restarts it when the oc process has
# exited; client-go ends a port-forward when one forwarded connection fails.
# Gives up after PORT_FORWARD_MAX_RESTARTS restarts for the same pod.
ensure_port_forward() {
  local namespace="$1" pod="$2" remote_port="$3"
  if [[ -n "${PORT_FORWARD_PID}" ]] && kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
    return 0
  fi
  if (( PORT_FORWARD_STARTS > PORT_FORWARD_MAX_RESTARTS )); then
    return 1
  fi
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    log "port-forward to ${pod} exited; restarting it"
  fi
  stop_port_forward
  PORT_FORWARD_STARTS=$((PORT_FORWARD_STARTS + 1))
  start_port_forward "${namespace}" "${pod}" "${remote_port}" "${WORK_DIR}/port-forward-${pod}-${PORT_FORWARD_STARTS}.log"
}

# Prints the names of running and ready pods matching a selector.
ready_pods() {
  oc get pods -n "$1" -l "$2" -o json | jq -r '.items[]
    | select(.status.phase == "Running")
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name' | sort
}

# Probes every instance of a static pod through a port-forward to its pod.
verify_instances() {
  local component="$1" namespace="$2" selector="$3" remote_port="$4" issuer_pattern="$5"
  local control_plane_nodes pods pod count
  control_plane_nodes="$(oc get nodes -l node-role.kubernetes.io/control-plane -o name | wc -l)"
  pods="$(ready_pods "${namespace}" "${selector}")"
  count="$(grep -c . <<<"${pods}" || true)"
  if (( control_plane_nodes == 0 || count != control_plane_nodes )); then
    record_result "${component} instances are ready" "fail" "found ${count} ready pods for ${control_plane_nodes} control plane nodes"
  else
    record_result "${component} instances are ready" "pass" "${count} ready pods for ${control_plane_nodes} control plane nodes"
  fi
  for pod in ${pods}; do
    stop_port_forward
    PORT_FORWARD_STARTS=0
    if ! ensure_port_forward "${namespace}" "${pod}" "${remote_port}"; then
      record_result "${component} ${pod} port ${remote_port} port-forward" "fail" "could not forward to the pod; no handshake was probed"
      stop_port_forward
      continue
    fi
    verify_endpoint "${component}" "${component} ${pod}:${remote_port}" 127.0.0.1 "${PORT_FORWARD_LOCAL_PORT}" localhost "${issuer_pattern}" \
      "${namespace}" "${pod}" "${remote_port}"
    if (( PORT_FORWARD_STARTS > 1 )); then
      log "port-forward to ${pod} was started ${PORT_FORWARD_STARTS} times"
    fi
    stop_port_forward
  done
}

verify_external_api() {
  local server host_port host port
  server="$(oc whoami --show-server)"
  host_port="${server#https://}"
  host_port="${host_port%%/*}"
  host="${host_port%:*}"
  port="${host_port##*:}"
  if [[ "${host}" == "${host_port}" ]]; then
    port=443
  fi
  # The host name is not printed; it is the server of the step kubeconfig.
  log "Probing the external API endpoint of the kubeconfig on port ${port}"
  verify_endpoint kube-apiserver "external API endpoint" "${host}" "${port}" "${host}" 'kube-apiserver'
}

print_expectations() {
  local profile="$1" component probe
  log "Expected handshake results for the ${profile} profile:"
  for component in kube-apiserver etcd; do
    for probe in "${PROBES[@]}"; do
      printf '  %-15s %-11s %s\n' "${component}" "${probe}" "$(expected_probe_result "${component}" "${profile}" "${probe}")"
    done
  done
  log "Expected IngressController status.tlsProfile minTLSVersion: $(component_min_version ingress "${profile}")"
}

main() {
  local profile="${INSTALL_CONFIG_TLS_PROFILE_TYPE:-}"
  mkdir -p "${VERIFY_ARTIFACT_DIR}"
  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT
  : >"${VERIFY_ARTIFACT_DIR}/handshakes.log"

  case "${profile}" in
    Modern|Intermediate|Old) ;;
    *) fatal "INSTALL_CONFIG_TLS_PROFILE_TYPE is a predefined profile" "expected Modern, Intermediate or Old, got '${profile}'" ;;
  esac
  for tool in oc jq openssl timeout; do
    if ! command -v "${tool}" >/dev/null; then
      fatal "required tool ${tool} is available" "${tool} is not installed in the step image"
    fi
  done
  log "Verifying the ${profile} TLS profile requested at install time"
  print_expectations "${profile}"

  write_probe_openssl_conf
  log "Self-testing the TLS probe client ($(openssl version))"
  if self_test_probe_client; then
    record_result "TLS probe client self-test" "pass" "the client and classification behave as expected against local servers"
  else
    fatal "TLS probe client self-test" "the probe client cannot be trusted; no cluster endpoint was probed"
  fi

  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  check_install_config "${profile}"

  if oc adm wait-for-stable-cluster --timeout="${STABLE_CLUSTER_TIMEOUT}"; then
    record_result "cluster operators are stable" "pass" "cluster operators settled before the checks"
  else
    record_result "cluster operators are stable" "fail" "cluster operators did not settle within ${STABLE_CLUSTER_TIMEOUT}; results below may be affected"
  fi

  check_apiserver_config "${profile}"
  check_ingress_profile "${profile}"
  save_observed_config
  verify_external_api
  verify_instances kube-apiserver openshift-kube-apiserver apiserver=true 6443 'kube-apiserver'
  verify_instances etcd openshift-etcd app=etcd,etcd=true 2379 'etcd'

  if (( $(failure_count) > 0 )); then
    log "$(failure_count) of ${#RESULT_NAMES[@]} checks failed; see ${VERIFY_ARTIFACT_DIR}/summary.txt"
    exit 1
  fi
  log "All ${#RESULT_NAMES[@]} checks passed"
}

# The offline test in hack/ sources this file with the variable set to "true"
# to exercise the functions without running the checks.
if [[ "${TLS_PROFILE_VERIFY_LIBRARY_ONLY:-false}" != "true" ]]; then
  main "$@"
fi
