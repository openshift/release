#!/bin/bash

# Behavioral tests for the OCM authentication boundary of the
# rosa-cluster-lease-checkout step.
#
# The real command script is executed end to end against stub binaries on
# PATH, so the assertions cover what the step actually does rather than a
# helper extracted from it. Nothing contacts a network, a cloud account or a
# cluster: oc, ocm and jq are all stubs, and every credential is a synthetic
# sentinel string that exists only inside the test's temporary directory.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REGISTRY_DIR="${SCRIPT_DIR}/../../ci-operator/step-registry/rosa/cluster-lease/checkout"
COMMAND_SCRIPT="${REGISTRY_DIR}/rosa-cluster-lease-checkout-commands.sh"
REF_FILE="${REGISTRY_DIR}/rosa-cluster-lease-checkout-ref.yaml"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

# Synthetic credentials. The assertions look for these sentinels; no real
# credential is involved and nothing is ever sent anywhere.
FAKE_CLIENT_ID="CLIENT_ID_SENTINEL"
FAKE_CLIENT_SECRET="CLIENT_SECRET_SENTINEL"
FAKE_OCM_TOKEN="OFFLINE_TOKEN_SENTINEL"
FAKE_HOST_KUBECONFIG="HOST_KUBECONFIG_SENTINEL"
# What a rejected login prints. A provider can quote the request it was sent,
# so the body carries a credential sentinel too.
FAKE_PROVIDER_BODY="PROVIDER_BODY_SENTINEL {\"error\":\"invalid_client\",\"client_secret\":\"${FAKE_CLIENT_SECRET}\"}"

CLUSTER_ID="fake-cluster-id"
CLUSTER_NAME="fake-cluster-name"
API_URL="https://api.fake-cluster.example.invalid:6443"
DEFAULT_PROFILE_NAME="rosa-lease-profile"
ARTIFACT_NAME="lease-checkout-auth.json"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  [[ -f "${file}" ]] || fail "expected '${expected}' in ${file}, which does not exist"
  if ! grep -Fq -- "${expected}" "${file}"; then
    sed -n '1,240p' "${file}" >&2
    fail "expected '${expected}' in ${file}"
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  [[ -f "${file}" ]] || fail "cannot check for '${unexpected}': ${file} does not exist"
  if grep -Fq -- "${unexpected}" "${file}"; then
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

assert_status() {
  local actual="$1" expected="$2" description="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${description}: expected status ${expected}, got ${actual}"
}

assert_missing() {
  local path="$1" description="$2"
  [[ ! -e "${path}" ]] || fail "${description}: expected ${path} not to exist"
}

assert_file_lines() {
  local file="$1" expected="$2" description="$3"
  local actual=0
  [[ ! -f "${file}" ]] || actual=$(wc -l < "${file}" | tr -d ' ')
  [[ "${actual}" == "${expected}" ]] || fail "${description}: expected ${expected} line(s) in ${file}, got ${actual}"
}

# Compare the artifact against the whole document it is supposed to be. An
# exact match is what proves the hand-rolled JSON stays well formed, including
# when a label the step did not choose reaches the allowlist.
assert_artifact() {
  local case_dir="$1" consumer="$2" profile="$3" mode="$4" environment="$5"
  local stage="$6" outcome="$7" status="$8"
  local artifact="${case_dir}/artifacts/${ARTIFACT_NAME}"
  local expected="${case_dir}/expected-artifact.json"
  [[ -f "${artifact}" ]] || fail "expected the step to write ${artifact}"
  cat > "${expected}" <<EOF
{
  "consumer": "${consumer}",
  "cluster_profile": "${profile}",
  "auth_mode": "${mode}",
  "environment": "${environment}",
  "stage": "${stage}",
  "outcome": "${outcome}",
  "exit_status": ${status}
}
EOF
  diff -u "${expected}" "${artifact}" >&2 || fail "the authentication record is not the expected document"
}

# No credential sentinel, and no provider response, may reach a public CI log
# or a published artifact, on either stream.
assert_no_secrets() {
  local case_dir="$1" sentinel target
  local -a targets=("${case_dir}/stdout.log" "${case_dir}/stderr.log")
  if [[ -f "${case_dir}/artifacts/${ARTIFACT_NAME}" ]]; then
    targets+=("${case_dir}/artifacts/${ARTIFACT_NAME}")
  fi
  for target in "${targets[@]}"; do
    for sentinel in "${FAKE_CLIENT_ID}" "${FAKE_CLIENT_SECRET}" "${FAKE_OCM_TOKEN}" \
      "${FAKE_HOST_KUBECONFIG}" "PROVIDER_BODY_SENTINEL" "invalid_client" \
      "sso-client-secret" "ocm-token"; do
      assert_not_contains "${target}" "${sentinel}"
    done
  done
}

make_mocks() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"

  cat > "${mock_dir}/oc" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == --kubeconfig=* ]]; then
  shift
fi
case "${1:-}" in
  get)
    case "${2:-}" in
      configmap) cat "${MOCK_STATE_DIR}/pool.json" ;;
      nodes) printf 'node-1 Ready\nnode-2 Ready\nnode-3 Ready\n' ;;
      *) exit 1 ;;
    esac
    ;;
  replace)
    cat >/dev/null
    printf 'replace\n' >> "${MOCK_STATE_DIR}/oc-replace-calls"
    ;;
  whoami)
    if [[ "${2:-}" == "--show-server" ]]; then
      printf '%s\n' "${MOCK_API_URL}"
    fi
    ;;
  *) exit 1 ;;
esac
EOF

  # Records which credential flags the step chose, never their values.
  cat > "${mock_dir}/ocm" <<'EOF'
#!/bin/bash
case "${1:-}" in
  login)
    printf 'login\n' >> "${MOCK_STATE_DIR}/ocm-login-calls"
    while [[ $# -gt 0 ]]; do
      case "${1}" in
        --url) printf 'url=%s\n' "${2:-}" >> "${MOCK_STATE_DIR}/ocm-login-flags"; shift 2 ;;
        --client-id|--client-secret|--token)
          printf '%s\n' "${1#--}" >> "${MOCK_STATE_DIR}/ocm-login-flags"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "${MOCK_LOGIN_STATUS}" != "0" ]]; then
      printf '%s\n' "${MOCK_PROVIDER_BODY}"
      printf 'Error: %s\n' "${MOCK_PROVIDER_BODY}" >&2
      exit "${MOCK_LOGIN_STATUS}"
    fi
    ;;
  get)
    printf '%s\n' "${2:-}" >> "${MOCK_STATE_DIR}/ocm-get-calls"
    printf '{"kubeconfig":"stub"}\n'
    ;;
  *) exit 1 ;;
esac
EOF

  # Answers only the filters this step issues on the path under test. An
  # unexpected filter is an error rather than an empty string, so a future
  # edit to the step cannot silently pass against a stale stub.
  cat > "${mock_dir}/jq" <<'EOF'
#!/bin/bash
filter=""
for arg in "$@"; do
  case "${arg}" in
    -*) continue ;;
  esac
  filter="${arg}"
done
input=$(cat)
case "${filter}" in
  *'= "in-use"'*) printf '%s\n' "${input}" ;;
  '.items | length') printf '1\n' ;;
  '.items[0]') cat "${MOCK_STATE_DIR}/cm.json" ;;
  *'.metadata.name'*) printf 'lease-cm-1\n' ;;
  *'rosa-cluster-lease/operators'*) printf '\n' ;;
  *'rosa-cluster-lease/status'*) printf 'available\n' ;;
  *'cluster-id'*) printf '%s\n' "${MOCK_CLUSTER_ID}" ;;
  *'cluster-name'*) printf '%s\n' "${MOCK_CLUSTER_NAME}" ;;
  *'.data.region'*) printf 'us-east-1\n' ;;
  *'ocm-env'*) printf '%s\n' "${MOCK_OCM_ENV}" ;;
  *'api-url'*) printf '%s\n' "${MOCK_API_URL}" ;;
  *'.kubeconfig'*) printf 'apiVersion: v1\nkind: Config\n' ;;
  *)
    printf 'mock jq: unhandled filter: %s\n' "${filter}" >&2
    exit 90
    ;;
esac
EOF

  chmod +x "${mock_dir}"/*
}

# Stage a cluster profile and run the real step script.
#   credentials:    which credential files the cluster profile carries
#   login_status:   the status the stubbed `ocm login` returns
#   login_env:      OCM_LOGIN_ENV for the step
#   operator:       OPERATOR_NAME, empty for an exclusive claim
#   profile_name:   CLUSTER_PROFILE_NAME, or __unset__ to leave it empty
#   artifact:       dir (writable), none (ARTIFACT_DIR unset), or blocked
#                   (the record's path is occupied and cannot be written)
# Every step input is passed explicitly so an exported variable in the
# surrounding shell cannot change what is under test.
run_checkout() {
  local case_name="$1" credentials="$2" login_status="$3" login_env="$4"
  local operator="${5:-}" profile_name="${6:-${DEFAULT_PROFILE_NAME}}" artifact="${7:-dir}"
  local case_dir="${TEST_ROOT}/${case_name}"
  local mock_dir="${case_dir}/bin"
  mkdir -p "${case_dir}/state" "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/profile"
  make_mocks "${mock_dir}"

  printf '%s\n' "${FAKE_HOST_KUBECONFIG}" > "${case_dir}/state/host-kubeconfig"
  printf '{"items":[{"metadata":{"name":"lease-cm-1"}}]}\n' > "${case_dir}/state/pool.json"
  printf '{"metadata":{"name":"lease-cm-1"}}\n' > "${case_dir}/state/cm.json"

  case "${credentials}" in
    sso)
      printf '%s' "${FAKE_CLIENT_ID}" > "${case_dir}/profile/sso-client-id"
      printf '%s' "${FAKE_CLIENT_SECRET}" > "${case_dir}/profile/sso-client-secret"
      ;;
    token)
      printf '%s' "${FAKE_OCM_TOKEN}" > "${case_dir}/profile/ocm-token"
      ;;
    both)
      printf '%s' "${FAKE_CLIENT_ID}" > "${case_dir}/profile/sso-client-id"
      printf '%s' "${FAKE_CLIENT_SECRET}" > "${case_dir}/profile/sso-client-secret"
      printf '%s' "${FAKE_OCM_TOKEN}" > "${case_dir}/profile/ocm-token"
      ;;
    none) ;;
    *) fail "unknown credential layout ${credentials}" ;;
  esac

  local artifact_dir="${case_dir}/artifacts"
  case "${artifact}" in
    dir) ;;
    none) artifact_dir="" ;;
    blocked) mkdir -p "${case_dir}/artifacts/${ARTIFACT_NAME}" ;;
    *) fail "unknown artifact layout ${artifact}" ;;
  esac

  [[ "${profile_name}" != "__unset__" ]] || profile_name=""

  CASE_DIR="${case_dir}"
  CASE_STATUS=0
  env \
    PATH="${mock_dir}:${PATH}" \
    MOCK_STATE_DIR="${case_dir}/state" \
    MOCK_LOGIN_STATUS="${login_status}" \
    MOCK_PROVIDER_BODY="${FAKE_PROVIDER_BODY}" \
    MOCK_CLUSTER_ID="${CLUSTER_ID}" \
    MOCK_CLUSTER_NAME="${CLUSTER_NAME}" \
    MOCK_API_URL="${API_URL}" \
    MOCK_OCM_ENV="" \
    LEASE_HOST_KUBECONFIG="${case_dir}/state/host-kubeconfig" \
    LEASE_NAMESPACE="rosa-cluster-lease" \
    LEASE_TYPE="classic-sts" \
    LEASE_ENV="" \
    LEASE_REGION="" \
    LEASE_VERSION="" \
    LEASE_CHECKOUT_TIMEOUT_MINUTES="30" \
    LEASE_FAIL_FAST_ON_EXHAUSTED="true" \
    OPERATOR_NAME="${operator}" \
    SHARED_DIR="${case_dir}/shared" \
    ARTIFACT_DIR="${artifact_dir}" \
    CLUSTER_PROFILE_DIR="${case_dir}/profile" \
    CLUSTER_PROFILE_NAME="${profile_name}" \
    OCM_LOGIN_ENV="${login_env}" \
    JOB_NAME="fake-job" \
    BUILD_ID="fake-build" \
    bash "${COMMAND_SCRIPT}" > "${case_dir}/stdout.log" 2> "${case_dir}/stderr.log" || CASE_STATUS=$?
}

# A rejected login names the facts a reader needs and nothing else.
test_rejected_login_reports_safe_summary() {
  run_checkout rejected_login sso 1 staging
  local log="${CASE_DIR}/stderr.log"

  assert_status "${CASE_STATUS}" 1 "rejected login"
  assert_contains "${log}" "ERROR: OCM authentication failed"
  assert_contains "${log}" "Consumer: exclusive"
  assert_contains "${log}" "Cluster profile: ${DEFAULT_PROFILE_NAME}"
  assert_contains "${log}" "Auth mode: sso-client-credentials"
  assert_contains "${log}" "Environment: staging"
  assert_contains "${log}" "Stage: ocm-login"
  assert_contains "${log}" "Exit status: 1"

  assert_artifact "${CASE_DIR}" exclusive "${DEFAULT_PROFILE_NAME}" \
    sso-client-credentials staging ocm-login failed 1
  assert_no_secrets "${CASE_DIR}"
}

# The rejected credential is not retried and no second credential is tried
# after it, so nothing downstream of authentication runs.
test_rejected_login_does_no_downstream_work() {
  run_checkout no_downstream both 1 staging
  assert_status "${CASE_STATUS}" 1 "rejected login"
  assert_file_lines "${CASE_DIR}/state/ocm-login-calls" 1 "rejected login must not be retried"
  assert_not_contains "${CASE_DIR}/state/ocm-login-flags" "token"
  assert_missing "${CASE_DIR}/state/ocm-get-calls" "no OCM resource is fetched after a rejected login"
  assert_missing "${CASE_DIR}/shared/kubeconfig" "no kubeconfig is written after a rejected login"
  assert_not_contains "${CASE_DIR}/stderr.log" "Lease checkout complete"
  assert_no_secrets "${CASE_DIR}"
}

# The step still exits with the status the login itself returned.
test_exit_status_parity() {
  local status
  for status in 1 7 70; do
    run_checkout "parity_${status}" sso "${status}" staging
    assert_status "${CASE_STATUS}" "${status}" "login exit ${status}"
    assert_contains "${CASE_DIR}/stderr.log" "Exit status: ${status}"
    assert_artifact "${CASE_DIR}" exclusive "${DEFAULT_PROFILE_NAME}" \
      sso-client-credentials staging ocm-login failed "${status}"
    assert_no_secrets "${CASE_DIR}"
  done
}

# A successful login keeps the established success semantics.
test_successful_login_completes_checkout() {
  run_checkout success sso 0 staging
  assert_status "${CASE_STATUS}" 0 "successful login"
  assert_contains "${CASE_DIR}/stderr.log" "Authenticated to OCM staging with auth mode sso-client-credentials"
  assert_contains "${CASE_DIR}/stderr.log" "Lease checkout complete"
  assert_not_contains "${CASE_DIR}/stderr.log" "OCM authentication failed"
  assert_contains "${CASE_DIR}/shared/kubeconfig" "apiVersion: v1"
  assert_artifact "${CASE_DIR}" exclusive "${DEFAULT_PROFILE_NAME}" \
    sso-client-credentials staging ocm-login succeeded 0
  assert_no_secrets "${CASE_DIR}"
}

# Credential selection precedence is unchanged: SSO client credentials win
# when the profile carries both halves, and the offline token is used when it
# is the only credential present.
test_credential_selection_precedence() {
  run_checkout precedence both 0 staging
  assert_status "${CASE_STATUS}" 0 "profile with both credential kinds"
  assert_contains "${CASE_DIR}/state/ocm-login-flags" "client-id"
  assert_contains "${CASE_DIR}/state/ocm-login-flags" "client-secret"
  assert_not_contains "${CASE_DIR}/state/ocm-login-flags" "token"
  assert_contains "${CASE_DIR}/stderr.log" "auth mode sso-client-credentials"
  assert_no_secrets "${CASE_DIR}"

  run_checkout offline_token token 0 staging
  assert_status "${CASE_STATUS}" 0 "offline token profile"
  assert_contains "${CASE_DIR}/state/ocm-login-flags" "token"
  assert_not_contains "${CASE_DIR}/state/ocm-login-flags" "client-id"
  assert_contains "${CASE_DIR}/stderr.log" "auth mode offline-token"
  assert_artifact "${CASE_DIR}" exclusive "${DEFAULT_PROFILE_NAME}" \
    offline-token staging ocm-login succeeded 0
  assert_no_secrets "${CASE_DIR}"

  run_checkout offline_token_rejected token 1 staging
  assert_status "${CASE_STATUS}" 1 "rejected offline token"
  assert_contains "${CASE_DIR}/stderr.log" "Auth mode: offline-token"
  assert_file_lines "${CASE_DIR}/state/ocm-login-calls" 1 "rejected offline token must not be retried"
  assert_no_secrets "${CASE_DIR}"
}

# A profile with no credential at all still fails at the selection stage with
# the established exit status, before any login is attempted.
test_missing_credentials_fail_at_selection() {
  run_checkout missing_credentials none 0 staging
  assert_status "${CASE_STATUS}" 1 "profile with no credentials"
  assert_contains "${CASE_DIR}/stderr.log" "ERROR: No OCM credentials found in cluster profile"
  assert_contains "${CASE_DIR}/stderr.log" "Stage: credential-selection"
  assert_contains "${CASE_DIR}/stderr.log" "Auth mode: none"
  assert_artifact "${CASE_DIR}" exclusive "${DEFAULT_PROFILE_NAME}" \
    none staging credential-selection failed 1
  assert_missing "${CASE_DIR}/state/ocm-login-calls" "no login is attempted without a credential"
  assert_no_secrets "${CASE_DIR}"
}

# An environment that is not a known alias is reported as a fixed placeholder,
# because a deployment named by URL can carry userinfo. The step still logs in
# against the configured value.
test_unknown_environment_is_not_echoed() {
  local url="https://api.unlisted.example.invalid"
  run_checkout unknown_environment sso 1 "${url}"
  assert_status "${CASE_STATUS}" 1 "unknown environment"
  assert_contains "${CASE_DIR}/stderr.log" "Environment: other"
  assert_not_contains "${CASE_DIR}/stderr.log" "${url}"
  assert_artifact "${CASE_DIR}" exclusive "${DEFAULT_PROFILE_NAME}" \
    sso-client-credentials other ocm-login failed 1
  assert_not_contains "${CASE_DIR}/artifacts/${ARTIFACT_NAME}" "${url}"
  assert_contains "${CASE_DIR}/state/ocm-login-flags" "url=${url}"
  assert_no_secrets "${CASE_DIR}"
}

# The consumer is the operator sharing the cluster when the step runs in
# per-operator mode, and a plain label passes through unchanged.
test_operator_is_reported_as_the_consumer() {
  run_checkout operator_consumer sso 1 staging lease-operator
  assert_status "${CASE_STATUS}" 1 "per-operator rejected login"
  assert_contains "${CASE_DIR}/stderr.log" "Consumer: lease-operator"
  assert_artifact "${CASE_DIR}" lease-operator "${DEFAULT_PROFILE_NAME}" \
    sso-client-credentials staging ocm-login failed 1
  assert_no_secrets "${CASE_DIR}"
}

# A label the step did not choose never reaches the log or the artifact
# verbatim, and the artifact stays the exact document it is supposed to be.
test_labels_are_allowlisted() {
  local hostile='evil" , "injected": "yes'
  run_checkout hostile_labels sso 1 staging "" "${hostile}"
  assert_status "${CASE_STATUS}" 1 "hostile cluster profile label"
  assert_contains "${CASE_DIR}/stderr.log" "Cluster profile: unsupported"
  assert_not_contains "${CASE_DIR}/stderr.log" "injected"
  assert_artifact "${CASE_DIR}" exclusive unsupported \
    sso-client-credentials staging ocm-login failed 1
  assert_no_secrets "${CASE_DIR}"

  local overlong="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  run_checkout overlong_label sso 1 staging "" "${overlong}"
  assert_status "${CASE_STATUS}" 1 "over-long cluster profile label"
  assert_contains "${CASE_DIR}/stderr.log" "Cluster profile: unsupported"
  assert_not_contains "${CASE_DIR}/stderr.log" "${overlong}"
  assert_no_secrets "${CASE_DIR}"

  run_checkout unset_profile sso 1 staging "" __unset__
  assert_status "${CASE_STATUS}" 1 "cluster profile name not set"
  assert_contains "${CASE_DIR}/stderr.log" "Cluster profile: none"
  assert_artifact "${CASE_DIR}" exclusive none \
    sso-client-credentials staging ocm-login failed 1
  assert_no_secrets "${CASE_DIR}"
}

# Writing the record is a diagnostic, so neither its absence nor a failure to
# write it may change the status the step reports.
test_artifact_write_never_changes_the_outcome() {
  run_checkout no_artifact_dir sso 7 staging "" "${DEFAULT_PROFILE_NAME}" none
  assert_status "${CASE_STATUS}" 7 "no ARTIFACT_DIR"
  assert_contains "${CASE_DIR}/stderr.log" "Exit status: 7"
  assert_missing "${CASE_DIR}/artifacts/${ARTIFACT_NAME}" "no record without ARTIFACT_DIR"
  assert_no_secrets "${CASE_DIR}"

  run_checkout blocked_artifact sso 7 staging "" "${DEFAULT_PROFILE_NAME}" blocked
  assert_status "${CASE_STATUS}" 7 "unwritable record on the failure path"
  assert_contains "${CASE_DIR}/stderr.log" "Exit status: 7"
  assert_contains "${CASE_DIR}/stderr.log" "WARNING: could not write the authentication record"
  assert_file_lines "${CASE_DIR}/state/ocm-login-calls" 1 "a failed record write must not cause a second login"
  assert_missing "${CASE_DIR}/state/ocm-get-calls" "a failed record write must not let the step continue"
  assert_no_secrets "${CASE_DIR}"

  run_checkout blocked_artifact_success sso 0 staging "" "${DEFAULT_PROFILE_NAME}" blocked
  assert_status "${CASE_STATUS}" 0 "unwritable record on the success path"
  assert_contains "${CASE_DIR}/stderr.log" "Lease checkout complete"
  assert_no_secrets "${CASE_DIR}"
}

# The step's documented contract has to keep naming what the step writes.
test_ref_documents_the_record() {
  assert_contains "${REF_FILE}" "${ARTIFACT_NAME}"
}

# These tests point the lease host credential at a fixture, which is only
# possible because the path carries a default rather than a constant. Pin the
# default so that seam can never change where CI reads the credential from,
# and keep the variable out of the step's declared environment.
test_credential_mount_default_is_pinned() {
  assert_contains "${COMMAND_SCRIPT}" \
    'LEASE_HOST_KUBECONFIG="${LEASE_HOST_KUBECONFIG:-/etc/rosa-cluster-lease-manager/sa.rosa-cluster-lease-manager.hosted-mgmt.config}"'
  assert_not_contains "${REF_FILE}" "LEASE_HOST_KUBECONFIG"
}

test_rejected_login_reports_safe_summary
test_rejected_login_does_no_downstream_work
test_exit_status_parity
test_successful_login_completes_checkout
test_credential_selection_precedence
test_missing_credentials_fail_at_selection
test_unknown_environment_is_not_echoed
test_operator_is_reported_as_the_consumer
test_labels_are_allowlisted
test_artifact_write_never_changes_the_outcome
test_ref_documents_the_record
test_credential_mount_default_is_pinned

echo "PASS: rosa cluster lease checkout OCM authentication tests"
