#!/bin/bash

# Offline regression tests for the DNS diagnostics of the
# rosa-cluster-wait-ready-cluster step. Every external command the step calls is
# mocked, so the tests never contact OCM, AWS, a management cluster or a resolver.
# The only file read outside the per-case temporary directory is the host's
# /etc/resolv.conf, which the step prints to label where a probe ran.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMAND_SCRIPT="${SCRIPT_DIR}/../../ci-operator/step-registry/rosa/cluster/wait-ready/cluster/rosa-cluster-wait-ready-cluster-commands.sh"
TEST_ROOT=$(mktemp -d)
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
  [[ -f "${file}" ]] || fail "expected file ${file} to exist"
  if ! grep -Fq -- "${expected}" "${file}"; then
    sed -n '1,240p' "${file}" >&2
    fail "expected '${expected}' in ${file}"
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  [[ -f "${file}" ]] || fail "expected file ${file} to exist"
  if grep -Fq -- "${unexpected}" "${file}"; then
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "expected file $1 to exist"
}

assert_file_absent() {
  [[ ! -e "$1" ]] || fail "did not expect file $1 to exist"
}

assert_status() {
  local actual="$1" expected="$2" description="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${description}: expected status ${expected}, got ${actual}"
}

assert_no_secrets() {
  local file="$1"
  assert_not_contains "${file}" 'MOCK_OCM_TOKEN_SECRET'
  assert_not_contains "${file}" 'MOCK_AWS_SECRET_KEY'
  # The step masks AWS account identifiers everywhere it echoes cluster output.
  assert_not_contains "${file}" '123456789012'
}

# Print the lines of one '=== <section> ===' block of an artifact.
section_of() {
  local file="$1" start="$2" end="$3"
  sed -n "/^=== ${start}/,/^=== ${end}/p" "${file}" | sed '1d;$d'
}

# Labels that let a reader tell where and when a probe ran, and keep a successful
# lookup from being read as evidence about the client that originally failed.
assert_probe_origin_labels() {
  local file="$1"
  assert_contains "${file}" "Probe origin: the ci-operator step pod running this step on the CI build farm."
  assert_contains "${file}" "Probe time:"
  assert_contains "${file}" "It is not the resolver used by the ROSA management cluster or by"
  assert_contains "${file}" "does not make it the same resolver."
  assert_contains "${file}" "CI pod resolver configuration (/etc/resolv.conf)"
  assert_contains "${file}" "It is not evidence of what the original client resolved, and it"
  assert_contains "${file}" "does not establish when any record was created, changed or propagated."
}

# Every DNS probe must be time-bounded, and it must have gone through the mocked dig
# unless the scenario made the bounding timeout itself fire first.
assert_probe_is_bounded_and_mocked() {
  local case_dir="$1" expected_host="$2" dig_runs="${3:-true}"
  assert_contains "${case_dir}/state/timeout-arguments" "10 dig +time=2 +tries=1 ${expected_host}"
  if [[ "${dig_runs}" == "true" ]]; then
    assert_contains "${case_dir}/state/dig-arguments" "+time=2 +tries=1 ${expected_host}"
  else
    assert_file_absent "${case_dir}/state/dig-arguments"
  fi
}

make_mocks() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"

  cat > "${mock_dir}/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "${1:-}" >> "${MOCK_STATE_DIR}/sleep-delays"
exit 0
EOF

  cat > "${mock_dir}/timeout" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/timeout-arguments"
if [[ "${MOCK_SCENARIO}" == "dns_probe_timeout" && "$*" == *dig* ]]; then
  exit 124
fi
while [[ "${1:-}" == -* || "${1:-}" =~ ^[0-9]+[smhd]?$ ]]; do
  shift
done
exec "$@"
EOF

  cat > "${mock_dir}/dig" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/dig-arguments"
if [[ "${MOCK_SCENARIO}" == "dns_probe_failure" ]]; then
  echo "dig: couldn't get address for the configured resolver" >&2
  exit 9
fi
if [[ "$*" == *" NS "* ]]; then
  exit 0
fi
cat <<'ANSWER'
; <<>> DiG 9.16.23-RH <<>> mock
;; ANSWER SECTION:
MOCK_DIG_ANSWER 60 IN A 203.0.113.10
;; SERVER: 172.30.0.10#53(172.30.0.10)
ANSWER
EOF

  cat > "${mock_dir}/aws" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/aws-arguments"
if [[ "${MOCK_SCENARIO}" != "dns_full" ]]; then
  # No cloud credentials: the step must degrade gracefully.
  exit 1
fi
case "$*" in
  *"sts get-caller-identity"*)
    printf '{"Account":"123456789012"}\n'
    ;;
  *"list-hosted-zones-by-name"*)
    printf '{"HostedZones":[{"Name":"ci-rosa-h-test.example.devshift.org.","Id":"/hostedzone/MOCKZONE"}]}\n'
    ;;
  *"list-resource-record-sets"*)
    printf '{"ResourceRecordSets":[]}\n'
    ;;
esac
exit 0
EOF

  # Unused by the hosted-control-plane scenarios below; kept so that a Classic scenario
  # can never reach the real CLI.
  cat > "${mock_dir}/ocm" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/ocm-arguments"
exit 1
EOF

  cat > "${mock_dir}/rosa" <<'EOF'
#!/bin/bash
set -o nounset
state="${MOCK_STATE_DIR}"
printf '%s\n' "$*" >> "${state}/rosa-arguments"

bump() {
  local name="$1" count=0
  [[ ! -f "${state}/${name}" ]] || count=$(cat "${state}/${name}")
  count=$(( count + 1 ))
  printf '%s' "${count}" > "${state}/${name}"
  printf '%s' "${count}"
}

dns_error_line() {
  printf '2026-11-17 16:1%s:35 +0000 UTC hostedclusters ci-rosa-h-test dial tcp: lookup api-%s.ci-rosa-h-test.example.devshift.org on 172.30.0.10:53: no such host\n' "$1" "$1"
}

long_padding() {
  local line i
  line=$(printf 'p%.0s' $(seq 1 400))
  for i in $(seq 1 500); do
    printf '2026-11-17 16:00:00 +0000 UTC hostedclusters ci-rosa-h-test pad-%04d %s\n' "${i}" "${line}"
  done
}

short_padding() {
  local i
  for i in $(seq 1 2000); do
    printf '2026-11-17 16:00:00 +0000 UTC ci-rosa-h-test short-%04d\n' "${i}"
  done
}

case "${1:-}" in
  login|verify)
    exit 0
    ;;
  whoami)
    printf '{"AWS Account ID":"123456789012"}\n'
    exit 0
    ;;
  list)
    printf '[]\n'
    exit 0
    ;;
  describe)
    if [[ "${2:-}" != "cluster" ]]; then
      printf '{}\n'
      exit 0
    fi
    count=$(bump describe-count)
    cluster_state="installing"
    if (( MOCK_READY_AFTER > 0 )) && (( count >= MOCK_READY_AFTER )); then
      cluster_state="ready"
    fi
    api_url="null"
    if [[ "${MOCK_SCENARIO}" == "dns_full" ]]; then
      api_url='"https://api.ci-rosa-h-test.example.devshift.org:443"'
    fi
    cat <<JSON
{
  "state": "${cluster_state}",
  "name": "ci-rosa-h-test",
  "dns": {"base_domain": "example.devshift.org"},
  "api": {"url": ${api_url}},
  "console": {"url": null},
  "infra_id": null,
  "product": {"id": "rosa"},
  "status": {"description": "cluster is installing"}
}
JSON
    exit 0
    ;;
  logs)
    count=$(bump install-log-count)
    case "${MOCK_SCENARIO}" in
      clean)
        printf '2026-11-17 16:11:00 +0000 UTC hostedclusters ci-rosa-h-test Reconciliation active on resource\n'
        ;;
      non_dns_fatal)
        printf '2026-11-17 16:11:00 +0000 UTC hostedclusters ci-rosa-h-test LimitExceeded: too many addresses\n'
        ;;
      dns_late)
        # The DNS error only shows up in the log re-fetched after the failure.
        if (( count == 1 )); then
          printf '2026-11-17 16:11:00 +0000 UTC hostedclusters ci-rosa-h-test LimitExceeded: too many addresses\n'
        else
          printf '2026-11-17 16:14:00 +0000 UTC hostedclusters ci-rosa-h-test dial tcp: lookup api.ci-rosa-h-test.example.devshift.org on 172.30.0.10:53: no such host\n'
        fi
        ;;
      dns_repeat)
        # A new, distinct DNS error on every health check, with no fatal pattern, so the
        # wait loop keeps running. Padding makes the log far larger than the byte cap.
        long_padding
        for i in $(seq 1 "${count}"); do
          dns_error_line "${i}"
        done
        ;;
      dns_oversized)
        # One enormous DNS line, carrying an account identifier and the ANSI sequences
        # this step's own log() emits through retry_cmd.
        big=$(printf 'x%.0s' $(seq 1 200000))
        printf '\033[1m2026-11-17 16:12:35 +0000 UTC hostedclusters ci-rosa-h-test role arn:aws:iam::123456789012:role/installer dial tcp: lookup api.ci-rosa-h-test.example.devshift.org on 172.30.0.10:53: no such host %s\033[0m\n' "${big}"
        printf '2026-11-17 16:13:20 +0000 UTC hostedclusters ci-rosa-h-test failed to create token for KMS provider service account\n'
        ;;
      dns_line_cap)
        short_padding
        printf '2026-11-17 16:13:20 +0000 UTC hostedclusters ci-rosa-h-test failed to create token for KMS provider service account: dial tcp: lookup api.ci-rosa-h-test.example.devshift.org on 172.30.0.10:53: no such host\n'
        ;;
      dns_chronology)
        if (( count == 1 )); then
          printf '2026-11-17 16:12:35 +0000 UTC hostedclusters ci-rosa-h-test lookup api.ci-rosa-h-test.example.devshift.org on 172.30.0.10:53: no such host\n'
          printf '2026-11-17 16:12:40 +0000 UTC hostedclusters ci-rosa-h-test role arn:aws:iam::123456789012:role/installer could not be assumed\n'
          printf '2026-11-17 16:13:20 +0000 UTC hostedclusters ci-rosa-h-test failed to create token for KMS provider service account: dial tcp: lookup api.ci-rosa-h-test.example.devshift.org on 172.30.0.10:53: no such host\n'
        else
          # The log the step re-fetches after it gives up no longer shows the DNS error.
          printf '2026-11-17 16:14:40 +0000 UTC hostedclusters ci-rosa-h-test Kube APIServer deployment is available\n'
          printf '2026-11-17 16:15:51 +0000 UTC hostedclusters ci-rosa-h-test The hosted control plane is available\n'
        fi
        ;;
      *)
        printf '2026-11-17 16:12:35 +0000 UTC hostedclusters ci-rosa-h-test lookup api.ci-rosa-h-test.example.devshift.org on 172.30.0.10:53: no such host\n'
        printf '2026-11-17 16:13:20 +0000 UTC hostedclusters ci-rosa-h-test failed to create token for KMS provider service account: dial tcp: lookup api.ci-rosa-h-test.example.devshift.org on 172.30.0.10:53: no such host\n'
        ;;
    esac
    exit 0
    ;;
esac
exit 0
EOF

  # The CI image that runs these tests (quay.io/openshift/ci:ci_shellcheck_latest)
  # ships no jq, so fall back to a stand-in that understands only the filters this
  # step uses. Real jq is used whenever it is installed.
  if ! command -v jq >/dev/null; then
    cat > "${mock_dir}/jq" <<'EOF'
#!/bin/bash
set -o nounset

raw=false
filter=""
input_file=""
for arg in "$@"; do
  case "${arg}" in
    -r|--raw-output) raw=true ;;
    -*) ;;
    *)
      if [[ -z "${filter}" ]]; then
        filter="${arg}"
      else
        input_file="${arg}"
      fi
      ;;
  esac
done

if [[ -n "${input_file}" ]]; then
  input=$(cat "${input_file}" 2>/dev/null || true)
else
  input=$(cat)
fi
input=$(printf '%s' "${input}" | tr '\n' ' ')

# Object mutation (record_cluster): keep the document as it is.
if [[ "${filter}" == *'+='* ]]; then
  printf '%s\n' "${input:-{\}}"
  exit 0
fi

default=""
has_default=false
if [[ "${filter}" == *'//'* ]]; then
  has_default=true
  default="${filter#*//}"
  default="${default#"${default%%[![:space:]]*}"}"
  default="${default%"${default##*[![:space:]]}"}"
  default="${default#\"}"
  default="${default%\"}"
  [[ "${default}" != "empty" ]] || default=""
  filter="${filter%%//*}"
  filter="${filter%"${filter##*[![:space:]]}"}"
fi

scalar_of() {
  local key="$1" json="$2"
  printf '%s' "${json}" \
    | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|null|true|false|-?[0-9.]+)" \
    | head -1 \
    | sed -E "s/^\"${key}\"[[:space:]]*:[[:space:]]*//"
}

object_of() {
  local key="$1" json="$2"
  printf '%s' "${json}" | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\{[^}]*\}" | head -1
}

case "${filter}" in
  '."AWS Account ID"') out=$(scalar_of 'AWS Account ID' "${input}") ;;
  '.state'|'.name'|'.infra_id'|'.timers') out=$(scalar_of "${filter#.}" "${input}") ;;
  '.api.url') out=$(scalar_of url "$(object_of api "${input}")") ;;
  '.console.url') out=$(scalar_of url "$(object_of console "${input}")") ;;
  '.dns.base_domain') out=$(scalar_of base_domain "$(object_of dns "${input}")") ;;
  '.product.id') out=$(scalar_of id "$(object_of product "${input}")") ;;
  '.status.description') out=$(scalar_of description "$(object_of status "${input}")") ;;
  *) out="" ;;
esac

if [[ -z "${out}" || "${out}" == "null" ]]; then
  if [[ "${has_default}" == true ]]; then
    [[ -z "${default}" ]] || printf '%s\n' "${default}"
    exit 0
  fi
  printf 'null\n'
  exit 0
fi

if [[ "${raw}" == true ]]; then
  out="${out#\"}"
  out="${out%\"}"
fi
printf '%s\n' "${out}"
EOF
  fi

  chmod +x "${mock_dir}"/*
}

run_script() {
  local scenario="$1" case_dir="$2" ready_after="${3:-0}" block_observation="${4:-false}"
  local mock_dir="${case_dir}/bin"
  mkdir -p "${case_dir}/state" "${case_dir}/tmp" "${case_dir}/artifacts" "${case_dir}/shared" "${case_dir}/profile"
  make_mocks "${mock_dir}"
  # A directory where the first snapshot belongs makes that write fail for any user.
  [[ "${block_observation}" != "true" ]] || mkdir -p "${case_dir}/artifacts/dns-observation-01.txt"
  printf '%s' 'MOCK_OCM_TOKEN_SECRET' > "${case_dir}/profile/ocm-token"
  printf '[default]\naws_access_key_id = MOCKID\naws_secret_access_key = MOCK_AWS_SECRET_KEY\n' > "${case_dir}/profile/.awscred"
  printf '%s' 'mock-cluster-id' > "${case_dir}/shared/cluster-id"
  printf '%s' '{}' > "${case_dir}/shared/cluster-config"

  env \
    PATH="${mock_dir}:${PATH}" \
    TMPDIR="${case_dir}/tmp" \
    MOCK_SCENARIO="${scenario}" \
    MOCK_STATE_DIR="${case_dir}/state" \
    MOCK_READY_AFTER="${ready_after}" \
    ARTIFACT_DIR="${case_dir}/artifacts" \
    SHARED_DIR="${case_dir}/shared" \
    CLUSTER_PROFILE_DIR="${case_dir}/profile" \
    LEASED_RESOURCE=us-west-2 \
    REGION="" \
    OCM_LOGIN_ENV=staging \
    HOSTED_CP=true \
    CLUSTER_TIMEOUT=9000 \
    STALL_TIMEOUT=3600 \
    bash "${COMMAND_SCRIPT}" > "${case_dir}/output.log" 2>&1
}

new_case() {
  local case_dir="${TEST_ROOT}/$1"
  mkdir -p "${case_dir}"
  printf '%s' "${case_dir}"
}

# The install log is re-fetched (and ${ARTIFACT_DIR}/.install.log written) only once the
# step gives up. The observation snapshot must keep the earlier chronology.
test_dns_chronology_survives_install_log_refetch() {
  local case_dir rc
  case_dir=$(new_case dns-chronology)
  set +e
  run_script dns_chronology "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local observation="${case_dir}/artifacts/dns-observation-01.txt"
  assert_file_exists "${observation}"
  assert_contains "${observation}" "16:12:35 +0000 UTC hostedclusters ci-rosa-h-test lookup api.ci-rosa-h-test.example.devshift.org on 172.30.0.10:53: no such host"
  assert_contains "${observation}" "failed to create token for KMS provider service account"
  assert_contains "${observation}" "Observed by: rosa-cluster-wait-ready-cluster, install-log health check after 5 polls with an unchanged cluster state"
  assert_contains "${observation}" "OCM cluster state at observation: installing"
  assert_contains "${observation}" "Observed at:"
  assert_probe_origin_labels "${observation}"
  assert_probe_is_bounded_and_mocked "${case_dir}" "api.ci-rosa-h-test.example.devshift.org"
  assert_contains "${observation}" "MOCK_DIG_ANSWER"
  # Account identifiers are masked in the snapshot, as elsewhere in the step.
  assert_contains "${observation}" "arn:aws:iam::1234***:role/installer"
  assert_no_secrets "${observation}"

  # The later install log no longer carries the DNS error; the snapshot is the only
  # artifact that still shows when it was observed.
  assert_file_exists "${case_dir}/artifacts/.install.log"
  assert_not_contains "${case_dir}/artifacts/.install.log" "no such host"
  # Diagnostics are still collected, and they point at the preserved chronology.
  assert_contains "${case_dir}/artifacts/dns-diagnostics.txt" "Earlier DNS errors were seen in install-log output while the step was still waiting."
  assert_contains "${case_dir}/output.log" "DNS-related error observed in install-log output; snapshot saved to"
  assert_no_secrets "${case_dir}/output.log"
}

# Failure-time diagnostics must label probe origin and time, and must not claim the CI
# pod's resolver is the management cluster's.
test_failure_diagnostics_label_probe_origin_and_time() {
  local case_dir rc
  case_dir=$(new_case dns-persistent)
  set +e
  run_script dns_persistent "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_file_exists "${diagnostics}"
  assert_contains "${diagnostics}" "Captured by: rosa-cluster-wait-ready-cluster, running in a ci-operator step pod"
  assert_contains "${diagnostics}" "(UTC, after the step declared the install failed)"
  assert_contains "${diagnostics}" "=== DNS probe from this CI step pod ==="
  assert_contains "${diagnostics}" "were saved alongside this file as dns-observation-NN.txt; at most 3 are kept, so a"
  assert_contains "${diagnostics}" "(queried from this CI pod)"
  # No cloud credentials are available to the test, and none are gathered for them.
  assert_contains "${diagnostics}" "AWS credentials not available for Route 53 lookup"
  assert_probe_origin_labels "${diagnostics}"
  assert_file_exists "${case_dir}/artifacts/dns-observation-01.txt"
  assert_no_secrets "${diagnostics}"
}

# The step source must no longer claim that the CI pod's own resolver is the management
# cluster's CoreDNS, which was the inaccuracy this change set out to correct.
test_script_makes_no_management_cluster_resolver_claim() {
  if grep -n "CoreDNS" "${COMMAND_SCRIPT}" >&2; then
    fail "the step must not attribute the CI pod's resolver to management-cluster CoreDNS"
  fi
}

# A failing or timing-out diagnostic command must not change the step result or stop the
# remaining diagnostics from being written.
test_probe_failures_do_not_change_step_result() {
  local scenario case_dir rc dig_runs
  for scenario in dns_probe_failure dns_probe_timeout; do
    dig_runs=true
    [[ "${scenario}" != "dns_probe_timeout" ]] || dig_runs=false
    case_dir=$(new_case "probe-${scenario}")
    set +e
    run_script "${scenario}" "${case_dir}"
    rc=$?
    set -e
    assert_status "${rc}" 1 "${scenario} must fail exactly like the baseline fatal error"
    assert_contains "${case_dir}/output.log" "ERROR: Fatal error detected in install logs:"
    assert_file_exists "${case_dir}/artifacts/dns-observation-01.txt"
    assert_probe_origin_labels "${case_dir}/artifacts/dns-observation-01.txt"
    assert_contains "${case_dir}/artifacts/dns-observation-01.txt" "=== End DNS error observation 1 ==="
    assert_file_exists "${case_dir}/artifacts/dns-diagnostics.txt"
    assert_contains "${case_dir}/artifacts/dns-diagnostics.txt" "=== End DNS Diagnostics ==="
    assert_probe_is_bounded_and_mocked "${case_dir}" "api.ci-rosa-h-test.example.devshift.org" "${dig_runs}"
    assert_no_secrets "${case_dir}/output.log"
  done
}

# Non-DNS failures keep their existing fail-fast behaviour and collect no DNS artifacts.
test_non_dns_failure_behaviour_is_unchanged() {
  local case_dir rc
  case_dir=$(new_case non-dns-fatal)
  set +e
  run_script non_dns_fatal "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "non-DNS fatal install error"
  assert_contains "${case_dir}/output.log" "ERROR: Fatal error detected in install logs:"
  assert_contains "${case_dir}/output.log" "LimitExceeded"
  assert_file_exists "${case_dir}/artifacts/.install.log"
  assert_file_absent "${case_dir}/artifacts/dns-observation-01.txt"
  assert_file_absent "${case_dir}/artifacts/dns-diagnostics.txt"
  assert_file_absent "${case_dir}/state/dig-arguments"
}

# A DNS error that only appears in the post-failure log must not be reported as an
# earlier observation.
test_unobserved_dns_error_is_not_claimed_as_observed() {
  local case_dir rc
  case_dir=$(new_case dns-late)
  set +e
  run_script dns_late "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"
  assert_file_absent "${case_dir}/artifacts/dns-observation-01.txt"
  assert_contains "${case_dir}/artifacts/dns-diagnostics.txt" "The wait loop's periodic install-log health checks recorded no DNS error."
  assert_contains "${case_dir}/artifacts/dns-diagnostics.txt" "evidence that no earlier DNS error occurred."
}

# A healthy install must stay unaffected: no diagnostics, no probes, exit 0.
test_successful_install_collects_no_dns_diagnostics() {
  local case_dir rc
  case_dir=$(new_case clean)
  set +e
  run_script clean "${case_dir}" 8
  rc=$?
  set -e
  assert_status "${rc}" 0 "healthy install"
  assert_file_absent "${case_dir}/artifacts/dns-observation-01.txt"
  assert_file_absent "${case_dir}/artifacts/dns-diagnostics.txt"
  assert_file_absent "${case_dir}/state/dig-arguments"
  assert_contains "${case_dir}/shared/api.url" "https://api.ci-rosa-h-test.example.devshift.org:443"
}

# Repeated, distinct DNS errors are capped in count and in size, and the wait loop keeps
# running because none of them is a fatal pattern.
test_observations_are_bounded() {
  local case_dir rc
  case_dir=$(new_case dns-repeat)
  set +e
  run_script dns_repeat "${case_dir}" 26
  rc=$?
  set -e
  assert_status "${rc}" 0 "non-fatal DNS errors must not fail the step"

  local -i count
  count=$(find "${case_dir}/artifacts" -maxdepth 1 -name 'dns-observation-*.txt' | wc -l)
  (( count == 3 )) || fail "expected 3 bounded observations, got ${count}"
  assert_file_absent "${case_dir}/artifacts/dns-observation-04.txt"
  assert_contains "${case_dir}/output.log" "keeping the first 3 observations only."

  # Each snapshot keeps only a bounded tail of a much larger install log.
  local observation="${case_dir}/artifacts/dns-observation-01.txt"
  local -i snapshot_size
  section_of "${observation}" "Install-log output snapshot" "DNS probe taken at this observation" \
    > "${case_dir}/observation-01-snapshot"
  snapshot_size=$(wc -c < "${case_dir}/observation-01-snapshot")
  # 65536 bytes of log plus the blank line that separates the section from the next one.
  (( snapshot_size <= 65538 )) || fail "expected a snapshot of at most 65536 bytes, got ${snapshot_size}"
  assert_not_contains "${case_dir}/observation-01-snapshot" "pad-0001 "
  assert_contains "${case_dir}/observation-01-snapshot" "pad-0500 "

  # Only newly seen DNS lines are listed, so each observation adds information; the
  # bounded snapshot below that list still carries the full context.
  local new_lines="${case_dir}/observation-02-new-lines"
  section_of "${case_dir}/artifacts/dns-observation-02.txt" "DNS-related lines not seen" "Install-log output snapshot" \
    > "${new_lines}"
  assert_contains "${new_lines}" "lookup api-2.ci-rosa-h-test.example.devshift.org"
  assert_not_contains "${new_lines}" "lookup api-1.ci-rosa-h-test.example.devshift.org on"
  assert_contains "${case_dir}/artifacts/dns-observation-02.txt" "lookup api-1.ci-rosa-h-test.example.devshift.org on"

  # The de-duplication state is a temporary file; it must not be left behind.
  [[ -z "$(grep -rl "no such host" "${case_dir}/tmp" 2>/dev/null)" ]] \
    || fail "expected no leftover temporary DNS state in ${case_dir}/tmp"
}

# The line cap binds for logs made of many short lines.
test_snapshot_line_cap() {
  local case_dir rc
  case_dir=$(new_case dns-line-cap)
  set +e
  run_script dns_line_cap "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local -i lines
  section_of "${case_dir}/artifacts/dns-observation-01.txt" "Install-log output snapshot" "DNS probe taken at this observation" \
    > "${case_dir}/snapshot"
  lines=$(wc -l < "${case_dir}/snapshot")
  (( lines <= 201 )) || fail "expected at most 200 snapshot lines, got ${lines}"
  (( lines >= 150 )) || fail "expected the snapshot to keep its bounded tail, got ${lines} lines"
  assert_not_contains "${case_dir}/snapshot" "short-0001"
  assert_contains "${case_dir}/snapshot" "short-2000"
}

# A snapshot that cannot be written must not change the step result, must not be
# reported as saved, and must not be claimed in the failure-time diagnostics.
test_unwritable_snapshot_does_not_change_result() {
  local case_dir rc
  case_dir=$(new_case snapshot-unwritable)
  set +e
  run_script dns_persistent "${case_dir}" 0 true
  rc=$?
  set -e
  assert_status "${rc}" 1 "a failed snapshot write must not change the step result"
  assert_contains "${case_dir}/output.log" "ERROR: Fatal error detected in install logs:"
  assert_contains "${case_dir}/output.log" "but the snapshot could not be written."
  assert_not_contains "${case_dir}/output.log" "snapshot saved to"
  assert_contains "${case_dir}/artifacts/dns-diagnostics.txt" "0 bounded snapshot(s)"
}

# A single huge log line must not defeat the size bounds, the account mask or the ANSI
# stripping.
test_oversized_line_is_capped_and_masked() {
  local case_dir rc
  case_dir=$(new_case dns-oversized)
  set +e
  run_script dns_oversized "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"

  local observation="${case_dir}/artifacts/dns-observation-01.txt"
  local -i section_size file_size
  section_of "${observation}" "DNS-related lines not seen" "Install-log output snapshot" \
    > "${case_dir}/new-lines"
  section_size=$(wc -c < "${case_dir}/new-lines")
  # 8192 bytes of log lines plus the blank line that separates the sections.
  (( section_size <= 8194 )) || fail "expected the error-line section to be capped at 8192 bytes, got ${section_size}"
  file_size=$(wc -c < "${observation}")
  (( file_size <= 81920 )) || fail "expected a bounded observation file, got ${file_size} bytes"

  assert_no_secrets "${observation}"
  assert_contains "${observation}" "arn:aws:iam::1234***:role/installer"
  if grep -q "$(printf '\033')" "${observation}"; then
    fail "expected ANSI escape sequences to be stripped from ${observation}"
  fi
}

# With an API URL and cloud credentials available, the probe host comes from the URL and
# the Route 53 dump is labelled with its read time.
test_api_url_and_route53_labelling() {
  local case_dir rc
  case_dir=$(new_case dns-full)
  set +e
  run_script dns_full "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 1 "fatal install error"
  assert_probe_is_bounded_and_mocked "${case_dir}" "api.ci-rosa-h-test.example.devshift.org"

  local diagnostics="${case_dir}/artifacts/dns-diagnostics.txt"
  assert_contains "${diagnostics}" "=== Route 53 hosted zone records ==="
  assert_contains "${diagnostics}" "Record state as read at"
  assert_contains "${diagnostics}" "history, so this says nothing about when a record was created or changed."
  assert_no_secrets "${diagnostics}"
}

test_dns_chronology_survives_install_log_refetch
test_failure_diagnostics_label_probe_origin_and_time
test_script_makes_no_management_cluster_resolver_claim
test_probe_failures_do_not_change_step_result
test_non_dns_failure_behaviour_is_unchanged
test_unobserved_dns_error_is_not_claimed_as_observed
test_successful_install_collects_no_dns_diagnostics
test_observations_are_bounded
test_snapshot_line_cap
test_unwritable_snapshot_does_not_change_result
test_oversized_line_is_capped_and_masked
test_api_url_and_route53_labelling

echo "PASS: rosa cluster wait-ready DNS diagnostics tests"
