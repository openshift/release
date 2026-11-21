#!/bin/bash

# Behavioral tests for the OCM authentication path shared by the two ROSA
# cluster lease steps. They run entirely offline against a mock ocm binary and
# only ever use synthetic credential values.
#
# Requires a Linux host with GNU coreutils, matching the ci_shellcheck_latest
# image the step-registry-shellcheck job runs in: `stat -c`, `base64 -w0`,
# `find -mindepth` and /proc/<pid>/cmdline. That image has no jq and no
# python3, so the suite mocks jq for the script under test and reads the
# generated JSON with the small helpers below, exactly as the sibling
# github-downstream-sync-commands_test.sh mocks every binary it needs.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REGISTRY_DIR="${SCRIPT_DIR}/../../ci-operator/step-registry/rosa/cluster-lease"
CONTROLLER_SCRIPT="${REGISTRY_DIR}/controller/rosa-cluster-lease-controller-commands.sh"
HEALTH_SCRIPT="${REGISTRY_DIR}/health/rosa-cluster-lease-health-commands.sh"
TEST_ROOT=$(mktemp -d)

# Synthetic credentials. The sentinels are what the assertions look for; no
# real credential is involved and nothing ever contacts a server.
FAKE_CLIENT_ID="svc-acct-lease-CLIENT_ID_SENTINEL"
FAKE_CLIENT_SECRET="CLIENT_SECRET_SENTINEL"
FAKE_BEARER_TOKEN=""
FAKE_OFFLINE_TOKEN=""
# A five segment token whose protected header is a JWE header: base64 of
# {"alg":"dir","enc":"A256GCM","cty":"JWT","kid":"ki"} with the "==" padding
# removed, which is the shape config.IsEncryptedToken re-pads and decodes.
FAKE_ENCRYPTED_TOKEN="eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIiwiY3R5IjoiSldUIiwia2lkIjoia2kifQ.a2V5.aXY.Y2lwaGVy.dGFn"
# Five segments, but the first one is not a JWE header: it does not re-pad to
# valid base64. `ocm login` would hand this to its JWT parser and fail.
FAKE_FIVE_PART_NOT_JWE="aGVhZGVy.a2V5.aXY.Y2lwaGVy.dGFn"
# Five segments and a decodable JSON header, but without the "enc" claim.
FAKE_FIVE_PART_PLAIN_HEADER="eyJhbGciOiJkaXIiLCJjdHkiOiJKV1QifQ.a2V5.aXY.Y2lwaGVy.dGFn"
# Header {"enc":1,"cty":"JWT","kid":"x"}: it re-pads to valid base64, so the
# decode succeeds and only the type check can reject it. JWETokenHeader
# declares Encryption as a string, so a numeric "enc" fails Go's
# json.Unmarshal.
FAKE_FIVE_PART_NUMERIC_ENC="eyJlbmMiOjEsImN0eSI6IkpXVCIsImtpZCI6IngifQ.a2V5.aXY.Y2lwaGVy.dGFn"
# Stands in for a password smuggled through the userinfo of an OCM_LOGIN_ENV
# URL, which the gateway guard rejects and must not echo.
FAKE_URL_PASSWORD="URL_PASSWORD_SENTINEL"

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  if ! grep -Fq -- "${expected}" "${file}"; then
    sed -n '1,120p' "${file}" >&2
    fail "expected '${expected}' in ${file}"
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "${unexpected}" "${file}"; then
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

assert_equals() {
  local actual="$1" expected="$2" description="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${description}: expected '${expected}', got '${actual}'"
}

# No credential value may appear in anything a CI log or a process listing can
# show. The client identifier is allowed, but only as the bounded prefix.
assert_no_secrets() {
  local file="$1"
  [[ -f "${file}" ]] || fail "expected ${file} to exist before checking it for secrets"
  assert_not_contains "${file}" "${FAKE_CLIENT_SECRET}"
  assert_not_contains "${file}" "${FAKE_BEARER_TOKEN}"
  assert_not_contains "${file}" "${FAKE_OFFLINE_TOKEN}"
  assert_not_contains "${file}" "${FAKE_ENCRYPTED_TOKEN}"
  assert_not_contains "${file}" "${FAKE_CLIENT_ID}"
}

assert_file_exists() {
  local file="$1" description="$2"
  [[ -e "${file}" ]] || fail "${description}: ${file} is missing"
}

# Readers for the flat, single-line JSON the step writes. Deliberately small:
# the only documents they parse are the ones this suite causes to be written.
json_string() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || fail "json_string: ${file} is missing"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${file}" | head -n1
}

json_has() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || fail "json_has: ${file} is missing"
  if grep -q "\"${key}\"[[:space:]]*:" "${file}"; then
    printf 'true'
  else
    printf 'false'
  fi
}

b64url() {
  base64 -w0 | tr '+/' '-_' | tr -d '='
}

make_jwt() {
  local typ="$1" header payload
  header=$(printf '%s' '{"alg":"none","typ":"JWT"}' | b64url)
  payload=$(printf '{"typ":"%s","exp":4102444800}' "${typ}" | b64url)
  printf '%s.%s.%s' "${header}" "${payload}" "signature"
}

# A header golang-jwt refuses: no "alg", so ParseUnverified never reaches the
# claims. The payload is a perfectly good Bearer payload.
make_jwt_without_alg() {
  local header payload
  header=$(printf '%s' '{"typ":"JWT"}' | b64url)
  payload=$(printf '%s' '{"typ":"Bearer","exp":4102444800}' | b64url)
  printf '%s.%s.%s' "${header}" "${payload}" "signature"
}

# A well formed header with an arbitrary payload, for claims the classifier
# has to refuse.
make_jwt_with_payload() {
  local header payload
  header=$(printf '%s' '{"alg":"none","typ":"JWT"}' | b64url)
  payload=$(printf '%s' "$1" | b64url)
  printf '%s.%s.%s' "${header}" "${payload}" "signature"
}

make_jwt_without_typ() {
  local header payload
  header=$(printf '%s' '{"alg":"none","typ":"JWT"}' | b64url)
  payload=$(printf '%s' '{"exp":4102444800}' | b64url)
  printf '%s.%s.%s' "${header}" "${payload}" "signature"
}

FAKE_BEARER_TOKEN=$(make_jwt Bearer)
FAKE_OFFLINE_TOKEN=$(make_jwt Offline)

# A mock `ocm` that records how it was invoked, refuses to accept a credential
# on its command line, and answers `ocm token` according to MOCK_SCENARIO.
make_mocks() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"

  cat > "${mock_dir}/ocm" <<'EOF'
#!/bin/bash
set -o nounset

argv=$(tr '\0' ' ' < "/proc/$$/cmdline")
printf '%s\n' "${argv}" >> "${MOCK_STATE_DIR}/ocm-argv"
if grep -Eq 'SENTINEL|--client-secret|--token[ =]|--password' <<< "${argv}"; then
  printf 'credential material reached the ocm command line\n' >&2
  exit 97
fi
printf '%s\n' "${OCM_CONFIG:-<unset>}" >> "${MOCK_STATE_DIR}/ocm-config-path"

if [[ "${1:-}" == "token" ]]; then
  count=0
  [[ ! -f "${MOCK_STATE_DIR}/token-count" ]] || count=$(cat "${MOCK_STATE_DIR}/token-count")
  count=$((count + 1))
  printf '%s' "${count}" > "${MOCK_STATE_DIR}/token-count"
  cp "${OCM_CONFIG}" "${MOCK_STATE_DIR}/ocm-config-${count}.json"
  stat -c '%a' "${OCM_CONFIG}" >> "${MOCK_STATE_DIR}/ocm-config-modes"
  stat -c '%a' "$(dirname "${OCM_CONFIG}")" >> "${MOCK_STATE_DIR}/ocm-config-dir-modes"
  for staged in client-id client-secret token; do
    stat -c "${staged}=%a" "$(dirname "${OCM_CONFIG}")/${staged}" \
      >> "${MOCK_STATE_DIR}/staged-credential-modes"
  done
  case "${MOCK_SCENARIO:-ok}" in
    auth_rejected)
      # Shape mirrors a real rejection, including the server echoing the
      # offending value back, so the redaction path is exercised.
      printf 'Error: Can'"'"'t get token: sso returned 401 for secret %s\nmulti\nline\n' \
        "${CRED_ECHO:-none}" >&2
      exit 1
      ;;
    auth_rejected_then_ok)
      if (( count < 3 )); then
        # `ocm token` saves the configuration with a truncating write; model a
        # save that failed part way, so an attempt that does not re-stage the
        # seed configuration reads an empty file.
        : > "${OCM_CONFIG}"
        printf 'Error: Can'"'"'t get token: sso returned 503\n' >&2
        exit 1
      fi
      ;;
    auth_rejected_oversized)
      printf 'Error: Can'"'"'t get token: ' >&2
      head -c 4000 /dev/zero | tr '\0' 'E' >&2
      printf '\n' >&2
      exit 1
      ;;
  esac
  printf 'ACCESS_TOKEN_VALUE\n'
  exit 0
fi
exit 0
EOF

  # The step image has jq; ci_shellcheck_latest does not, so jq is mocked like
  # every other binary this suite needs. It records its argv (jq is where the
  # credential values are handed to another process), and it implements only
  # the invocation shapes the step uses - anything else is a hard error, so a
  # change in the step that this mock no longer models fails loudly instead of
  # being silently mis-modelled.
  cat > "${mock_dir}/jq" <<'EOF'
#!/bin/bash
set -o nounset

argv=$(tr '\0' ' ' < "/proc/$$/cmdline")
printf '%s\n' "${argv}" >> "${MOCK_STATE_DIR}/jq-argv"
if grep -Eq 'SENTINEL' <<< "${argv}"; then
  printf 'credential material reached the jq command line\n' >&2
  exit 96
fi

names=() values=()
null_input=false filter="" file=""
while (( $# )); do
  case "$1" in
    --arg)     names+=("$2"); values+=("$3"); shift 3 ;;
    --rawfile) names+=("$2"); values+=("$(cat "$3")"); shift 3 ;;
    -n)  null_input=true; shift ;;
    -*)  shift ;;
    *)   if [[ -z "${filter}" ]]; then filter="$1"; else file="$1"; fi; shift ;;
  esac
done

lookup() {
  local wanted="$1" i
  for i in "${!names[@]}"; do
    if [[ "${names[$i]}" == "${wanted}" ]]; then printf '%s' "${values[$i]}"; return 0; fi
  done
  return 1
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "${value}"
}

if [[ "${null_input}" == true ]]; then
  # Object construction for ocm_write_config. MOCK_JQ_WRITE_FAILURES makes the
  # first N of them fail, modelling storage that cannot take the seed file.
  if (( ${MOCK_JQ_WRITE_FAILURES:-0} > 0 )); then
    failed=0
    [[ ! -f "${MOCK_STATE_DIR}/jq-write-failures" ]] || failed=$(cat "${MOCK_STATE_DIR}/jq-write-failures")
    if (( failed < MOCK_JQ_WRITE_FAILURES )); then
      printf '%s' "$((failed + 1))" > "${MOCK_STATE_DIR}/jq-write-failures"
      printf 'mock jq: simulated seed write failure\n' >&2
      exit 4
    fi
  fi
  # One shape per auth mode.
  if [[ "${filter}" == *'client_secret: $client_secret'* ]]; then
    printf '{"client_id":"%s","client_secret":"%s","token_url":"%s","url":"%s","scopes":["openid"]}\n' \
      "$(json_escape "$(lookup client_id)")" "$(json_escape "$(lookup client_secret)")" \
      "$(json_escape "$(lookup token_url)")" "$(json_escape "$(lookup url)")"
    exit 0
  fi
  if [[ "${filter}" == *'($field): $token'* ]]; then
    printf '{"%s":"%s","client_id":"%s","token_url":"%s","url":"%s","scopes":["openid"]}\n' \
      "$(json_escape "$(lookup field)")" "$(json_escape "$(lookup token)")" \
      "$(json_escape "$(lookup client_id)")" "$(json_escape "$(lookup token_url)")" \
      "$(json_escape "$(lookup url)")"
    exit 0
  fi
  printf 'mock jq: unsupported construction filter: %s\n' "${filter}" >&2
  exit 95
fi

if [[ "${filter}" == *'.enc'* ]]; then
  # ocm_token_config_field's JWE header probe: `jq -e`, exit status only.
  payload=$(cat)
  [[ "${payload}" == \{* ]] || exit 1
  # JWETokenHeader declares alg, enc and cty as strings, so a present but
  # non-string value is what makes Go's json.Unmarshal fail.
  for key in alg enc cty; do
    if grep -q "\"${key}\"[[:space:]]*:" <<< "${payload}" &&
       ! grep -q "\"${key}\"[[:space:]]*:[[:space:]]*\"" <<< "${payload}"; then
      exit 1
    fi
  done
  enc=$(sed -n 's/.*"enc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "${payload}" | head -n1)
  cty=$(sed -n 's/.*"cty"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "${payload}" | head -n1)
  [[ -n "${enc}" && "${cty}" == "JWT" ]] || exit 1
  exit 0
fi

if [[ "${filter}" == *'.alg | type'* ]]; then
  # ocm_token_config_field's JWS header probe: `jq -e`, exit status only.
  payload=$(cat)
  [[ "${payload}" == \{* ]] || exit 1
  grep -q '"alg"[[:space:]]*:[[:space:]]*"[^"]\+"' <<< "${payload}" || exit 1
  exit 0
fi

if [[ "${filter}" == *'.typ'* ]]; then
  # ocm_token_config_field: absent typ -> "" ; a present non-string typ is an
  # error, as it is in config.TokenType; anything else -> error.
  payload=$(cat)
  if [[ "${payload}" != \{* ]]; then
    printf 'mock jq: not an object\n' >&2
    exit 5
  fi
  if grep -q '"typ"[[:space:]]*:' <<< "${payload}" &&
     ! grep -q '"typ"[[:space:]]*:[[:space:]]*"' <<< "${payload}"; then
    printf 'mock jq: non-string typ\n' >&2
    exit 5
  fi
  printf '%s\n' "$(sed -n 's/.*"typ"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "${payload}" | head -n1)"
  exit 0
fi

if [[ "${filter}" == *'.access_token'* ]]; then
  # ocm_redact: emit the stored access and refresh tokens, one per line.
  for key in access_token refresh_token; do
    if [[ -f "${file}" ]]; then
      printf '%s\n' "$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${file}" | head -n1)"
    else
      printf '\n'
    fi
  done
  exit 0
fi

printf 'mock jq: unsupported filter: %s\n' "${filter}" >&2
exit 95
EOF

  cat > "${mock_dir}/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "${1}" >> "${MOCK_STATE_DIR}/sleep-delays"
exit 0
EOF

  chmod +x "${mock_dir}"/*
}

# Source the step script (it returns early when sourced) and run one of its
# authentication helpers with a staged cluster profile.
run_auth() {
  local script="$1" case_name="$2" scenario="$3" login_env="$4" trace="${5:-false}"
  local case_dir="${TEST_ROOT}/${case_name}"
  local -a trace_args=()
  mkdir -p "${case_dir}/state" "${case_dir}/tmp"
  make_mocks "${case_dir}/bin"
  [[ "${trace}" != "true" ]] || trace_args=(-x)

  env \
    PATH="${case_dir}/bin:${PATH}" \
    TMPDIR="${case_dir}/tmp" \
    MOCK_SCENARIO="${scenario}" \
    MOCK_STATE_DIR="${case_dir}/state" \
    MOCK_JQ_WRITE_FAILURES="${MOCK_JQ_WRITE_FAILURES:-0}" \
    CRED_ECHO="${CRED_ECHO:-none}" \
    CLUSTER_PROFILE_DIR="${case_dir}/profile" \
    OCM_CONFIG="" \
    OCM_KEYRING="${CASE_OCM_KEYRING:-}" \
    OCM_URL="${CASE_OCM_URL:-}" \
    OCM_LOGIN_ENV="${login_env}" \
    PROBE_SNIPPET="${PROBE_SNIPPET:-}" \
    bash "${trace_args[@]}" -c '
      set -o nounset -o errexit -o pipefail
      # shellcheck disable=SC1090
      source "$1"
      # Capture the status rather than letting errexit abort here, so the
      # probe lines below are emitted for failing cases too. The captured
      # status is still what this shell exits with.
      status=0
      ocm_authenticate || status=$?
      if [[ -n "${PROBE_SNIPPET}" ]]; then
        eval "${PROBE_SNIPPET}" || printf "probe_failed=%s\n" "$?"
      fi
      printf "status=%s\n" "${status}"
      printf "mode=%s\n" "${OCM_AUTH_MODE}"
      printf "field=%s\n" "${OCM_TOKEN_FIELD}"
      printf "current_env=%s\n" "${CURRENT_OCM_ENV}"
      printf "auth_dir=%s\n" "${OCM_AUTH_DIR}"
      exit "${status}"
    ' bash "${script}" > "${case_dir}/output.log" 2>&1 && echo 0 > "${case_dir}/status" ||
    echo $? > "${case_dir}/status"
}

stage_profile() {
  local case_name="$1"
  local profile="${TEST_ROOT}/${case_name}/profile"
  mkdir -p "${profile}"
  shift
  while (( $# > 0 )); do
    printf '%s' "$2" > "${profile}/$1"
    shift 2
  done
}

prepare_case() {
  local case_name="$1"
  mkdir -p "${TEST_ROOT}/${case_name}"
}

# --- tests ---------------------------------------------------------------

test_sso_client_credentials_never_reach_a_command_line() {
  prepare_case sso
  stage_profile sso \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token "${FAKE_OFFLINE_TOKEN}"
  CRED_ECHO="${FAKE_CLIENT_SECRET}" run_auth "${CONTROLLER_SCRIPT}" sso ok staging

  local dir="${TEST_ROOT}/sso"
  assert_equals "$(cat "${dir}/status")" 0 "sso client login should succeed"
  assert_contains "${dir}/output.log" "mode=sso-client"
  assert_contains "${dir}/output.log" "current_env=staging"
  # The mock exits 97 if a credential reaches argv; a clean run proves it did not.
  assert_no_secrets "${dir}/state/ocm-argv"

  local config="${dir}/state/ocm-config-1.json"
  assert_equals "$(json_string "${config}" client_id)" "${FAKE_CLIENT_ID}" "client_id in config"
  assert_equals "$(json_string "${config}" client_secret)" "${FAKE_CLIENT_SECRET}" "client_secret in config"
  assert_equals "$(json_string "${config}" url)" "https://api.stage.openshift.com" "staging gateway"
  assert_equals "$(json_string "${config}" token_url)" \
    "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" "token_url"
  assert_contains "${config}" '"scopes":["openid"]'
  assert_equals "$(json_has "${config}" access_token)" false "SSO config must not carry an access token"
  assert_equals "$(json_has "${config}" refresh_token)" false "SSO config must not carry a refresh token"
  # `ocm login` is never invoked: it would overwrite the seeded client_secret.
  assert_not_contains "${dir}/state/ocm-argv" "ocm login"
  assert_equals "$(head -n1 "${dir}/state/ocm-config-modes")" 600 "config file mode"
  assert_equals "$(head -n1 "${dir}/state/ocm-config-dir-modes")" 700 "config directory mode"
  # The staged credential files jq reads by path must be private too.
  assert_file_exists "${dir}/state/staged-credential-modes" "staged credential modes"
  assert_contains "${dir}/state/staged-credential-modes" "client-id=600"
  assert_contains "${dir}/state/staged-credential-modes" "client-secret=600"
  assert_contains "${dir}/state/staged-credential-modes" "token=600"
  # jq is handed the credentials by path, never by value: the shim exits 96 if
  # a sentinel reaches its argv, and it recorded a call here.
  assert_file_exists "${dir}/state/jq-argv" "jq argv recording"
  assert_contains "${dir}/state/jq-argv" "--rawfile"
  assert_no_secrets "${dir}/state/jq-argv"
  # The mock renders the object, so the requested scopes are asserted on the
  # filter the step actually passed rather than on the mock's own output.
  assert_contains "${dir}/state/jq-argv" 'scopes: ["openid"]'
}

test_pre_auth_diagnostics_are_bounded_and_non_secret() {
  local dir="${TEST_ROOT}/sso"
  assert_file_exists "${dir}/output.log" "the sso case must run before this one"
  assert_contains "${dir}/output.log" "OCM auth: mode=sso-client"
  assert_contains "${dir}/output.log" "client-id-prefix=svc-acct..."
  assert_contains "${dir}/output.log" "target-env=staging"
  assert_contains "${dir}/output.log" "gateway=https://api.stage.openshift.com"
  assert_no_secrets "${dir}/output.log"
}

test_token_fallback_classifies_token_types() {
  local -a cases=(
    "bearer:${FAKE_BEARER_TOKEN}:access_token"
    "offline:${FAKE_OFFLINE_TOKEN}:refresh_token"
    "refresh:$(make_jwt Refresh):refresh_token"
    "notyp:$(make_jwt_without_typ):access_token"
    "encrypted:${FAKE_ENCRYPTED_TOKEN}:refresh_token"
  )
  local entry name token expected dir
  for entry in "${cases[@]}"; do
    name="token-${entry%%:*}"
    token="${entry#*:}"
    expected="${token##*:}"
    token="${token%:*}"
    prepare_case "${name}"
    # No SSO pair in the profile, so the token fallback is selected.
    stage_profile "${name}" \
      sso-client-id "" \
      sso-client-secret "" \
      ocm-token "${token}"
    CRED_ECHO="${token}" run_auth "${CONTROLLER_SCRIPT}" "${name}" ok prod
    dir="${TEST_ROOT}/${name}"
    assert_equals "$(cat "${dir}/status")" 0 "${name} should authenticate"
    assert_contains "${dir}/output.log" "mode=token"
    assert_contains "${dir}/output.log" "field=${expected}"
    assert_contains "${dir}/output.log" "client-id-prefix=<none>"
    assert_equals "$(json_string "${dir}/state/ocm-config-1.json" "${expected}")" \
      "${token}" "${name} stored under ${expected}"
    assert_equals "$(json_string "${dir}/state/ocm-config-1.json" url)" \
      "https://api.openshift.com" "${name} production gateway"
    assert_equals "$(json_has "${dir}/state/ocm-config-1.json" client_secret)" false \
      "${name} must not carry a client secret"
    # Matches the client_id `ocm login --token` stores; the SDK default is the
    # same, but an empty value here would be a silent divergence.
    assert_equals "$(json_string "${dir}/state/ocm-config-1.json" client_id)" \
      "cloud-services" "${name} records the default OpenID client identifier"
    assert_contains "${dir}/state/jq-argv" 'scopes: ["openid"]'
    assert_no_secrets "${dir}/state/ocm-argv"
    assert_no_secrets "${dir}/output.log"
    # assert_no_secrets only knows the fixed sentinels, and two of these cases
    # mint their token here, so check this case's token explicitly. jq receives
    # it with --rawfile, so the recorded argument vector must hold the staging
    # path and never the token value itself.
    assert_contains "${dir}/state/jq-argv" "--rawfile"
    assert_not_contains "${dir}/state/jq-argv" "${token}"
    assert_not_contains "${dir}/state/ocm-argv" "${token}"
    assert_not_contains "${dir}/output.log" "${token}"
  done
}

test_sso_pair_wins_over_token() {
  local dir="${TEST_ROOT}/sso"
  assert_file_exists "${dir}/output.log" "the sso case must run before this one"
  # The sso case staged an ocm-token too; the SSO pair still won.
  assert_contains "${dir}/output.log" "mode=sso-client"
  assert_equals "$(json_has "${dir}/state/ocm-config-1.json" refresh_token)" false \
    "token must not be used while an SSO pair is present"
}

test_partial_sso_pair_falls_back_to_token() {
  prepare_case partial
  stage_profile partial \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "" \
    ocm-token "${FAKE_OFFLINE_TOKEN}"
  run_auth "${CONTROLLER_SCRIPT}" partial ok staging
  assert_equals "$(cat "${TEST_ROOT}/partial/status")" 0 "partial pair should fall back"
  assert_contains "${TEST_ROOT}/partial/output.log" "mode=token"
}

test_known_aliases_and_full_https_urls_resolve() {
  local -a cases=(
    "production:https://api.openshift.com"
    "prod:https://api.openshift.com"
    "prd:https://api.openshift.com"
    "staging:https://api.stage.openshift.com"
    "stage:https://api.stage.openshift.com"
    "stg:https://api.stage.openshift.com"
    "integration:https://api.integration.openshift.com"
    "int:https://api.integration.openshift.com"
    "https://api.example.openshift.com:https://api.example.openshift.com"
    # `ocm login` parsed a non-alias value with url.ParseRequestURI, which
    # lowercases the scheme, so this spelling must keep resolving.
    "HTTPS://api.example.openshift.com:https://api.example.openshift.com"
    # A legal RFC 3986 path, including sub-delims, must survive the guard.
    "https://api.example.openshift.com/ocm+v1:https://api.example.openshift.com/ocm+v1"
  )
  local entry alias expected name index=0
  for entry in "${cases[@]}"; do
    alias="${entry%:https://*}"
    expected="https://${entry##*:https://}"
    index=$((index + 1))
    name="alias-${index}"
    prepare_case "${name}"
    stage_profile "${name}" \
      sso-client-id "${FAKE_CLIENT_ID}" \
      sso-client-secret "${FAKE_CLIENT_SECRET}" \
      ocm-token ""
    run_auth "${CONTROLLER_SCRIPT}" "${name}" ok "${alias}"
    assert_equals "$(cat "${TEST_ROOT}/${name}/status")" 0 "alias ${alias} should authenticate"
    assert_equals "$(json_string "${TEST_ROOT}/${name}/state/ocm-config-1.json" url)" \
      "${expected}" "alias ${alias} resolution"
  done
}

test_unknown_environment_is_rejected() {
  # The userinfo case is why the diagnostic does not quote the rejected value:
  # a password embedded in the URL is printable and would survive sanitizing.
  local -a rejected=(
    "bogusalias"
    "http://api.example.com"
    "api.openshift.com"
    "https://svc:${FAKE_URL_PASSWORD}@api.openshift.com"
    ""
  )
  local value name index=0
  for value in "${rejected[@]}"; do
    index=$((index + 1))
    name="badenv-${index}"
    prepare_case "${name}"
    stage_profile "${name}" \
      sso-client-id "${FAKE_CLIENT_ID}" \
      sso-client-secret "${FAKE_CLIENT_SECRET}" \
      ocm-token ""
    run_auth "${CONTROLLER_SCRIPT}" "${name}" ok "${value}"
    [[ "$(cat "${TEST_ROOT}/${name}/status")" != 0 ]] ||
      fail "environment '${value}' should have been rejected"
    assert_contains "${TEST_ROOT}/${name}/output.log" "Unsupported OCM environment"
    # The rejected value never reaches the log, so neither does anything a
    # caller smuggled into it.
    assert_not_contains "${TEST_ROOT}/${name}/output.log" "${FAKE_URL_PASSWORD}"
    if [[ -n "${value}" ]]; then
      assert_not_contains "${TEST_ROOT}/${name}/output.log" "${value}"
    fi
    # Nothing may be written or validated for a rejected environment.
    [[ ! -f "${TEST_ROOT}/${name}/state/token-count" ]] ||
      fail "environment '${value}' must not reach credential validation"
  done
}

test_rejected_environment_value_stays_out_of_the_log() {
  prepare_case inject
  stage_profile inject \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  run_auth "${CONTROLLER_SCRIPT}" inject ok 'bogus
INJECTED: fake log line'
  [[ "$(cat "${TEST_ROOT}/inject/status")" != 0 ]] || fail "injected environment should be rejected"
  assert_contains "${TEST_ROOT}/inject/output.log" "Unsupported OCM environment"
  # Because the value is never echoed it can neither be quoted back nor become
  # a log line of its own.
  if grep -Fq 'INJECTED' "${TEST_ROOT}/inject/output.log"; then
    sed -n '1,20p' "${TEST_ROOT}/inject/output.log" >&2
    fail "rejected environment value reached the log"
  fi
  assert_not_contains "${TEST_ROOT}/inject/output.log" "bogus"
}

test_missing_credentials_fail_fast() {
  prepare_case missing
  stage_profile missing \
    sso-client-id "" \
    sso-client-secret "" \
    ocm-token ""
  run_auth "${CONTROLLER_SCRIPT}" missing ok staging
  assert_equals "$(cat "${TEST_ROOT}/missing/status")" 1 "missing credentials must exit 1"
  assert_contains "${TEST_ROOT}/missing/output.log" "No OCM credentials found in cluster profile"
  [[ ! -f "${TEST_ROOT}/missing/state/token-count" ]] || fail "no ocm call expected"
}

test_absent_profile_files_fail_fast() {
  prepare_case absent
  mkdir -p "${TEST_ROOT}/absent/profile"
  run_auth "${CONTROLLER_SCRIPT}" absent ok staging
  assert_equals "$(cat "${TEST_ROOT}/absent/status")" 1 "absent profile files must exit 1"
  assert_contains "${TEST_ROOT}/absent/output.log" "No OCM credentials found in cluster profile"
}

test_unrecognized_token_is_rejected() {
  # Each of these exercises a different rejection branch: the segment count,
  # an unknown "typ" claim (which `ocm login` also refuses), and a payload
  # segment whose length cannot be valid base64url.
  local -a tokens=(
    "notjwt:not-a-jwt"
    "unknowntyp:$(make_jwt Weird)"
    "badb64:$(printf '%s' '{"alg":"none"}' | b64url).A.sig"
    # Five segments alone is not enough: config.IsEncryptedToken also requires
    # a decodable JWE header carrying "enc" and a "cty" of JWT.
    "fivepartbadheader:${FAKE_FIVE_PART_NOT_JWE}"
    "fivepartnoenc:${FAKE_FIVE_PART_PLAIN_HEADER}"
    "fivepartnumericenc:${FAKE_FIVE_PART_NUMERIC_ENC}"
    # golang-jwt reads the header first: no "alg" means no classification,
    # whatever the payload says.
    "noalg:$(make_jwt_without_alg)"
    # config.TokenType errors on a present "typ" that is not a string, so
    # neither false nor null may fall back to the Bearer default.
    "falsetyp:$(make_jwt_with_payload '{"typ":false,"exp":4102444800}')"
    "nulltyp:$(make_jwt_with_payload '{"typ":null,"exp":4102444800}')"
  )
  local entry name token index=0
  for entry in "${tokens[@]}"; do
    name="badtoken-${entry%%:*}"
    token="${entry#*:}"
    index=$((index + 1))
    prepare_case "${name}"
    stage_profile "${name}" \
      sso-client-id "" \
      sso-client-secret "" \
      ocm-token "${token}"
    run_auth "${CONTROLLER_SCRIPT}" "${name}" ok staging
    assert_equals "$(cat "${TEST_ROOT}/${name}/status")" 1 "${name} must exit 1"
    assert_contains "${TEST_ROOT}/${name}/output.log" "not a recognized access or refresh token"
    assert_no_secrets "${TEST_ROOT}/${name}/output.log"
    [[ ! -f "${TEST_ROOT}/${name}/state/token-count" ]] ||
      fail "${name} must not reach credential validation"
  done
}

test_keyring_shadowing_the_config_fails_fast() {
  prepare_case keyring
  stage_profile keyring \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  CASE_OCM_KEYRING=pass run_auth "${CONTROLLER_SCRIPT}" keyring ok staging
  assert_equals "$(cat "${TEST_ROOT}/keyring/status")" 1 "OCM_KEYRING must fail fast"
  assert_contains "${TEST_ROOT}/keyring/output.log" "OCM_KEYRING is set"
}

test_ocm_url_shadowing_the_gateway_fails_fast() {
  prepare_case ocmurl
  stage_profile ocmurl \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  CASE_OCM_URL=https://api.elsewhere.invalid run_auth "${CONTROLLER_SCRIPT}" ocmurl ok staging
  assert_equals "$(cat "${TEST_ROOT}/ocmurl/status")" 1 "OCM_URL must fail fast"
  assert_contains "${TEST_ROOT}/ocmurl/output.log" "OCM_URL is set"
}

test_rejected_credentials_surface_a_sanitized_diagnostic() {
  prepare_case rejected
  stage_profile rejected \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  CRED_ECHO="${FAKE_CLIENT_SECRET}" run_auth "${CONTROLLER_SCRIPT}" rejected auth_rejected staging

  local dir="${TEST_ROOT}/rejected"
  assert_equals "$(cat "${dir}/status")" 1 "rejected credentials must propagate ocm's exit status"
  # The error is reported, not suppressed...
  assert_contains "${dir}/output.log" "OCM credential validation failed"
  assert_contains "${dir}/output.log" "sso returned 401 for secret"
  assert_contains "${dir}/output.log" "OCM authentication failed"
  # ...with the echoed credential replaced and the message kept to one line.
  assert_contains "${dir}/output.log" "<redacted>"
  assert_no_secrets "${dir}/output.log"
  assert_equals "$(grep -c 'OCM credential validation failed' "${dir}/output.log")" 3 \
    "controller retries credential validation three times"
  # The mock error spans three lines; it must arrive flattened onto the single
  # diagnostic line rather than as log lines of its own.
  assert_contains "${dir}/output.log" "for secret <redacted>?multi?line"
  if grep -qE '^(multi|line)$' "${dir}/output.log"; then
    fail "multi-line ocm error leaked extra log lines"
  fi
}

test_oversized_diagnostics_are_truncated() {
  prepare_case oversized
  stage_profile oversized \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  run_auth "${HEALTH_SCRIPT}" oversized auth_rejected_oversized staging
  assert_equals "$(cat "${TEST_ROOT}/oversized/status")" 1 "oversized error must still fail"
  assert_contains "${TEST_ROOT}/oversized/output.log" "<truncated>"
  # 4 KB of error must not reach the log; the line stays bounded.
  if awk 'length($0) > 1000 { found = 1 } END { exit !found }' "${TEST_ROOT}/oversized/output.log"; then
    fail "an unbounded diagnostic line reached the log"
  fi
}

test_oversized_environment_value_is_truncated() {
  local long_host
  long_host=$(printf 'a%.0s' {1..200})
  prepare_case longenv
  stage_profile longenv \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  run_auth "${CONTROLLER_SCRIPT}" longenv ok "https://${long_host}.example.com"
  assert_equals "$(cat "${TEST_ROOT}/longenv/status")" 0 "a long but valid URL is accepted"
  assert_contains "${TEST_ROOT}/longenv/output.log" "<truncated>"
  # The full value still reaches the configuration, only the log is bounded.
  assert_equals "$(json_string "${TEST_ROOT}/longenv/state/ocm-config-1.json" url)" \
    "https://${long_host}.example.com" "long URL stored verbatim"
}

test_accepted_gateway_url_cannot_inject_log_lines() {
  prepare_case gatewayinject
  stage_profile gatewayinject \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  # A would-be accepted https value carrying a newline and an escape sequence.
  run_auth "${CONTROLLER_SCRIPT}" gatewayinject ok 'https://api.stage.openshift.com
GATEWAY-INJECTED \e[31m'
  [[ "$(cat "${TEST_ROOT}/gatewayinject/status")" != 0 ]] ||
    fail "a gateway URL containing a newline must be rejected"
  if grep -Fq 'GATEWAY-INJECTED' "${TEST_ROOT}/gatewayinject/output.log"; then
    sed -n '1,20p' "${TEST_ROOT}/gatewayinject/output.log" >&2
    fail "injected gateway value escaped the diagnostic line"
  fi
  if grep -q "$(printf '\033')\[31m" "${TEST_ROOT}/gatewayinject/output.log"; then
    fail "injected escape sequence was rendered by echo -e"
  fi
}

test_controller_retry_backoff_and_recovery() {
  prepare_case retry
  stage_profile retry \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  run_auth "${CONTROLLER_SCRIPT}" retry auth_rejected_then_ok staging
  local dir="${TEST_ROOT}/retry"
  assert_equals "$(cat "${dir}/status")" 0 "controller should recover on the third attempt"
  assert_equals "$(cat "${dir}/state/token-count")" 3 "three validation attempts"
  assert_equals "$(tr '\n' ',' < "${dir}/state/sleep-delays")" "10,10," "two ten second backoffs"
  # The mock truncates the configuration on each rejection, the way a failed
  # `ocm token` save can, so every attempt has to re-stage the seed file.
  local attempt
  for attempt in 1 2 3; do
    assert_equals "$(json_string "${dir}/state/ocm-config-${attempt}.json" client_secret)" \
      "${FAKE_CLIENT_SECRET}" "attempt ${attempt} must re-stage the seed configuration"
    assert_equals "$(json_string "${dir}/state/ocm-config-${attempt}.json" url)" \
      "https://api.stage.openshift.com" "attempt ${attempt} keeps the resolved gateway"
  done
}

test_controller_retries_a_failed_seed_write() {
  prepare_case seedwrite
  stage_profile seedwrite \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  # The first two attempts cannot write the seed configuration; the third can.
  MOCK_JQ_WRITE_FAILURES=2 run_auth "${CONTROLLER_SCRIPT}" seedwrite ok staging
  local dir="${TEST_ROOT}/seedwrite"
  assert_equals "$(cat "${dir}/status")" 0 "a transient seed write failure must be retried"
  assert_contains "${dir}/output.log" "Failed to write the OCM configuration"
  # No validation may run against a configuration that was not written.
  assert_equals "$(cat "${dir}/state/token-count")" 1 "validation runs once the seed config exists"
  assert_equals "$(tr '\n' ',' < "${dir}/state/sleep-delays")" "10,10," "two ten second backoffs"
  assert_no_secrets "${dir}/output.log"
}

# The suite mocks jq, because the ci_shellcheck_latest image the job runs in
# has none, so every other test exercises the mock's model of a filter rather
# than the filter itself. Where a real jq is available, run the production
# classifier directly against it so a filter that stops matching that model
# cannot pass unnoticed.
test_token_classifier_under_real_jq() {
  if ! command -v jq > /dev/null 2>&1; then
    printf 'SKIP: no real jq on PATH; the classifier filters ran under the mock only\n'
    return 0
  fi
  local -a cases=(
    # Accepted, with the field `ocm login` would have written.
    "${FAKE_BEARER_TOKEN}:access_token"
    "${FAKE_OFFLINE_TOKEN}:refresh_token"
    "$(make_jwt Refresh):refresh_token"
    "$(make_jwt_without_typ):access_token"
    "${FAKE_ENCRYPTED_TOKEN}:refresh_token"
    # Rejected, each by a different rule the CLI applies.
    "${FAKE_FIVE_PART_NOT_JWE}:"
    "${FAKE_FIVE_PART_PLAIN_HEADER}:"
    "${FAKE_FIVE_PART_NUMERIC_ENC}:"
    "$(make_jwt_without_alg):"
    "$(make_jwt Weird):"
    "$(make_jwt_with_payload '{"typ":false,"exp":4102444800}'):"
    "$(make_jwt_with_payload '{"typ":null,"exp":4102444800}'):"
    "$(make_jwt_with_payload '{"typ":1,"exp":4102444800}'):"
    "not-a-jwt:"
  )
  local script
  for script in "${CONTROLLER_SCRIPT}" "${HEALTH_SCRIPT}"; do
    if ! (
      # shellcheck disable=SC1090
      source "${script}"
      status=0
      for entry in "${cases[@]}"; do
        token="${entry%:*}"
        expected="${entry##*:}"
        actual=$(ocm_token_config_field "${token}") || actual=""
        if [[ "${actual}" != "${expected}" ]]; then
          printf 'real jq: header %s classified as %s, expected %s\n' \
            "${token%%.*}" "${actual:-<rejected>}" "${expected:-<rejected>}" >&2
          status=1
        fi
      done
      exit "${status}"
    ); then
      fail "$(basename "${script}") classifies differently under real jq than under the mock"
    fi
  done
}

test_health_step_keeps_its_single_attempt() {
  prepare_case health-reject
  stage_profile health-reject \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  run_auth "${HEALTH_SCRIPT}" health-reject auth_rejected staging
  local dir="${TEST_ROOT}/health-reject"
  assert_equals "$(cat "${dir}/status")" 1 "health step must fail on rejection"
  assert_equals "$(cat "${dir}/state/token-count")" 1 "health step does not retry"
  [[ ! -f "${dir}/state/sleep-delays" ]] || fail "health step must not back off"
  assert_no_secrets "${dir}/output.log"
}

test_health_step_shares_the_config_based_path() {
  prepare_case health-ok
  stage_profile health-ok \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  run_auth "${HEALTH_SCRIPT}" health-ok ok integration
  local dir="${TEST_ROOT}/health-ok"
  assert_equals "$(cat "${dir}/status")" 0 "health step should authenticate"
  assert_contains "${dir}/output.log" "mode=sso-client"
  assert_equals "$(json_string "${dir}/state/ocm-config-1.json" url)" \
    "https://api.integration.openshift.com" "health step resolves the integration alias"
  assert_not_contains "${dir}/state/ocm-argv" "ocm login"
  assert_no_secrets "${dir}/state/ocm-argv"
}

test_staged_credentials_are_removed_on_exit() {
  local name dir auth_dir
  # Both the success and the failure cases must clean up; a missing auth_dir
  # probe is a test defect, not a reason to skip the assertion.
  for name in sso rejected health-reject health-ok retry; do
    dir="${TEST_ROOT}/${name}"
    assert_file_exists "${dir}/output.log" "${name} must run before this one"
    auth_dir=$(sed -n 's/^auth_dir=//p' "${dir}/output.log" | tail -n1)
    [[ -n "${auth_dir}" ]] ||
      fail "${name}: no auth_dir probe recorded, cleanup is unverified"
    [[ ! -e "${auth_dir}" ]] || fail "${name}: staged credentials left behind in ${auth_dir}"
    [[ -z "$(find "${dir}/tmp" -mindepth 1 -print -quit)" ]] ||
      fail "${name}: temporary credential directory survived"
  done
}

test_ensure_env_switches_environments() {
  prepare_case ensureenv
  stage_profile ensureenv \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token ""
  PROBE_SNIPPET='
    ocm_ensure_env staging && printf "same_env_rc=0\n"
    ocm_ensure_env prod && printf "switch_rc=0\n"
    printf "after_switch=%s\n" "${CURRENT_OCM_ENV}"
    ocm_ensure_env nonsense || printf "bad_env_rc=%s\n" "$?"
    printf "after_bad=%s\n" "${CURRENT_OCM_ENV}"
  ' run_auth "${CONTROLLER_SCRIPT}" ensureenv ok staging
  local dir="${TEST_ROOT}/ensureenv"
  assert_equals "$(cat "${dir}/status")" 0 "initial authentication should succeed"
  # Already on the target environment: no second validation.
  assert_contains "${dir}/output.log" "same_env_rc=0"
  assert_contains "${dir}/output.log" "switch_rc=0"
  assert_contains "${dir}/output.log" "after_switch=prod"
  # A switch rewrites the shared configuration with the new gateway.
  assert_equals "$(cat "${dir}/state/token-count")" 2 "one validation per environment switch"
  assert_equals "$(json_string "${dir}/state/ocm-config-1.json" url)" \
    "https://api.stage.openshift.com" "first login targets staging"
  assert_equals "$(json_string "${dir}/state/ocm-config-2.json" url)" \
    "https://api.openshift.com" "switch targets production"
  # A rejected environment fails and leaves the current one untouched.
  assert_contains "${dir}/output.log" "bad_env_rc=1"
  assert_contains "${dir}/output.log" "after_bad=prod"
  assert_no_secrets "${dir}/state/ocm-argv"
  assert_no_secrets "${dir}/state/jq-argv"
}

test_xtrace_never_exposes_credentials() {
  prepare_case xtrace
  stage_profile xtrace \
    sso-client-id "${FAKE_CLIENT_ID}" \
    sso-client-secret "${FAKE_CLIENT_SECRET}" \
    ocm-token "${FAKE_OFFLINE_TOKEN}"
  CRED_ECHO="${FAKE_CLIENT_SECRET}" run_auth "${CONTROLLER_SCRIPT}" xtrace ok staging true
  local dir="${TEST_ROOT}/xtrace"
  assert_equals "$(cat "${dir}/status")" 0 "traced run should still authenticate"
  assert_not_contains "${dir}/output.log" "${FAKE_CLIENT_SECRET}"
  assert_not_contains "${dir}/output.log" "${FAKE_OFFLINE_TOKEN}"
  assert_no_secrets "${dir}/state/ocm-argv"
}

test_sso_client_credentials_never_reach_a_command_line
test_pre_auth_diagnostics_are_bounded_and_non_secret
test_sso_pair_wins_over_token
test_token_fallback_classifies_token_types
test_partial_sso_pair_falls_back_to_token
test_known_aliases_and_full_https_urls_resolve
test_unknown_environment_is_rejected
test_rejected_environment_value_stays_out_of_the_log
test_missing_credentials_fail_fast
test_absent_profile_files_fail_fast
test_unrecognized_token_is_rejected
test_keyring_shadowing_the_config_fails_fast
test_ocm_url_shadowing_the_gateway_fails_fast
test_rejected_credentials_surface_a_sanitized_diagnostic
test_oversized_diagnostics_are_truncated
test_oversized_environment_value_is_truncated
test_accepted_gateway_url_cannot_inject_log_lines
test_controller_retry_backoff_and_recovery
test_controller_retries_a_failed_seed_write
test_token_classifier_under_real_jq
test_health_step_keeps_its_single_attempt
test_health_step_shares_the_config_based_path
test_ensure_env_switches_environments
test_staged_credentials_are_removed_on_exit
test_xtrace_never_exposes_credentials

echo "PASS: rosa cluster lease OCM authentication tests"
