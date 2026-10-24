#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMAND_SCRIPT="${SCRIPT_DIR}/../../ci-operator/step-registry/github/downstream-sync/github-downstream-sync-commands.sh"
REF_FILE="${SCRIPT_DIR}/../../ci-operator/step-registry/github/downstream-sync/github-downstream-sync-ref.yaml"
TEST_ROOT=$(mktemp -d)
LOCALHOST_SERVER_PID=""
cleanup() {
  if [[ -n "${LOCALHOST_SERVER_PID}" ]]; then
    kill "${LOCALHOST_SERVER_PID}" 2>/dev/null || true
    wait "${LOCALHOST_SERVER_PID}" 2>/dev/null || true
  fi
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
    sed -n '1,240p' "${file}" >&2
    fail "expected '${expected}' in ${file}"
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "${unexpected}" "${file}"; then
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

assert_matches() {
  local file="$1" expected="$2"
  if ! grep -Eq -- "${expected}" "${file}"; then
    sed -n '1,240p' "${file}" >&2
    fail "expected pattern '${expected}' in ${file}"
  fi
}

assert_count() {
  local file="$1" expected="$2"
  local actual=0
  if [[ -f "${file}" ]]; then
    actual=$(cat "${file}")
  fi
  [[ "${actual}" == "${expected}" ]] || fail "expected ${file} to contain ${expected}, got ${actual}"
}

assert_status() {
  local actual="$1" expected="$2" description="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${description}: expected status ${expected}, got ${actual}"
}

assert_backoffs() {
  local file="$1"
  local actual=""
  [[ ! -f "${file}" ]] || actual=$(cat "${file}")
  [[ "${actual}" == $'2\n4' ]] || fail "expected exact retry backoffs 2 and 4 in ${file}, got '${actual}'"
}

make_mocks() {
  local mock_dir="$1"
  mkdir -p "${mock_dir}"

  cat > "${mock_dir}/openssl" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "dgst" ]]; then
  cat >/dev/null
  printf 'SIGNATURE_SECRET'
elif [[ "$*" == *'-A'* ]]; then
  cat >/dev/null
  printf 'BASIC_HEADER_SECRET'
else
  cat >/dev/null
  printf 'BEARER_AUTH_ARGV_SENTINEL'
fi
EOF

  cat > "${mock_dir}/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "${1}" >> "${MOCK_STATE_DIR}/sleep-delays"
exit 0
EOF

  cat > "${mock_dir}/go" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat > "${mock_dir}/jq" <<'EOF'
#!/bin/bash
input=$(cat)
case "$*" in
  *'.id'*)
    printf '%s\n' '1234'
    ;;
  *'.token'*)
    printf '%s\n' 'TOKEN_AUTH_ARGV_SENTINEL'
    ;;
  *'DownStream Merge'*)
    if [[ "${input}" == *'DownStream Merge'* ]]; then
      printf '42\td/s-merge-open\n'
    fi
    ;;
  *'.number'*)
    printf '%s\n' '77'
    ;;
  *'-nc'*)
    printf '%s\n' '{}'
    ;;
  *)
    ;;
esac
EOF

  cat > "${mock_dir}/timeout" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/timeout-arguments"
count=0
[[ ! -f "${MOCK_STATE_DIR}/timeout-count" ]] || count=$(cat "${MOCK_STATE_DIR}/timeout-count")
printf '%s' "$((count + 1))" > "${MOCK_STATE_DIR}/timeout-count"

case "${MOCK_SCENARIO}" in
  timeout_124_persistent|deadline_exhausted)
    exit 124
    ;;
  timeout_137_persistent)
    exit 137
    ;;
esac

while [[ "${1:-}" == --* || "${1:-}" == *s ]]; do
  shift
done
exec "$@"
EOF

  cat > "${mock_dir}/curl" <<'EOF'
#!/bin/bash
set -o nounset
set -o errexit

argv=$(tr '\0' '\n' < "/proc/$$/cmdline")
printf '%s\n--\n' "${argv}" >> "${MOCK_STATE_DIR}/curl-argv"
if grep -Eq 'AUTH_ARGV_SENTINEL|Authorization:' <<< "${argv}"; then
  printf 'curl authorization leaked into argv\n' >&2
  exit 97
fi
printf 'safe\n' >> "${MOCK_STATE_DIR}/curl-argv-inspections"

output_file=""
header_file=""
url=""
while (( $# > 0 )); do
  case "$1" in
    --output)
      output_file="$2"
      shift 2
      ;;
    --dump-header)
      header_file="$2"
      shift 2
      ;;
    --header|-H)
      curl_header="$2"
      if [[ "${curl_header}" == @* ]]; then
        curl_header_file=${curl_header#@}
        printf '%s\n' "${curl_header_file}" >> "${MOCK_STATE_DIR}/curl-auth-header-paths"
        stat -c '%a' "${curl_header_file}" >> "${MOCK_STATE_DIR}/curl-auth-header-modes"
        cat "${curl_header_file}" >> "${MOCK_STATE_DIR}/curl-received-headers"
      else
        printf '%s\n' "${curl_header}" >> "${MOCK_STATE_DIR}/curl-received-headers"
      fi
      shift 2
      ;;
    --write-out|--connect-timeout|--max-time|-X|-d)
      shift 2
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "${url}" in
  */installation)
    operation=installation
    body='{"id":1234}'
    status=200
    ;;
  */access_tokens)
    operation=token
    body='{"token":"TOKEN_AUTH_ARGV_SENTINEL"}'
    status=201
    ;;
  *'/pulls?'*)
    operation=pulls
    if [[ "${MOCK_SCENARIO}" == "post_ambiguous" || "${MOCK_SCENARIO}" == "xtrace" || "${MOCK_SCENARIO}" == "auth_argv" ]]; then
      body='[]'
    else
      body='[{"number":42,"head":{"ref":"d/s-merge-open"},"title":"DownStream Merge [01-01-2026]"}]'
    fi
    status=200
    ;;
  */matching-refs/*)
    operation=refs
    body='[]'
    status=200
    ;;
  */pulls)
    operation=create-pr
    body='{"number":77}'
    status=201
    ;;
  */comments)
    operation=comment
    body='{"id":88}'
    status=201
    ;;
  *)
    operation=other
    body='{}'
    status=200
    ;;
esac

count_file="${MOCK_STATE_DIR}/curl-${operation}-count"
count=0
[[ ! -f "${count_file}" ]] || count=$(cat "${count_file}")
count=$((count + 1))
printf '%s' "${count}" > "${count_file}"

headers="HTTP/2 ${status} mock\r\n"
case "${MOCK_SCENARIO}:${operation}" in
  http_transient:installation)
    if (( count == 1 )); then
      body='{"message":"temporary outage"}'
      status=503
    fi
    ;;
  http_503_persistent:installation)
    body='{"message":"temporary outage"}'
    status=503
    ;;
  curl_28_persistent:installation)
    printf 'curl: (28) Operation timed out\n' >&2
    printf '000'
    exit 28
    ;;
  rate_limit_403:installation)
    if (( count == 1 )); then
      body='{"message":"API rate limit exceeded"}'
      status=403
      headers="HTTP/2 403 mock\r\nX-RateLimit-Remaining: 0\r\nRetry-After: 0\r\n"
    fi
    ;;
  rate_limit_403_retry_after_08:installation)
    body='{"message":"API rate limit exceeded"}'
    status=403
    headers="HTTP/2 403 mock\r\nX-RateLimit-Remaining: 0\r\nRetry-After: 08\r\n"
    ;;
  rate_limit_403_retry_after_0008:installation)
    body='{"message":"API rate limit exceeded"}'
    status=403
    headers="HTTP/2 403 mock\r\nX-RateLimit-Remaining: 0\r\nRetry-After: 0008\r\n"
    ;;
  rate_limit_403_retry_after_oversized:installation)
    body='{"message":"API rate limit exceeded"}'
    status=403
    headers="HTTP/2 403 mock\r\nX-RateLimit-Remaining: 0\r\nRetry-After: 99999999999999999999999999999999999999\r\n"
    ;;
  rate_limit_403_http_date:installation)
    if (( count == 1 )); then
      body='{"message":"API rate limit exceeded"}'
      status=403
      headers="HTTP/2 403 mock\r\nX-RateLimit-Remaining: 0\r\nRetry-After: Thu, 01 Jan 1970 00:00:00 GMT\r\n"
    fi
    ;;
  rate_limit_403_reset:installation)
    if (( count == 1 )); then
      body='{"message":"API rate limit exceeded"}'
      status=403
      headers="HTTP/2 403 mock\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: $(date +%s)\r\n"
    fi
    ;;
  http_403_permanent:installation)
    body='{"message":"Resource not accessible"}'
    status=403
    ;;
  http_permanent:installation)
    body='{"message":"Bad credentials"}'
    status=401
    ;;
  post_ambiguous:create-pr)
    printf 'committed create-pr mutation\n' >> "${MOCK_STATE_DIR}/mutations"
    printf 'curl: (52) Empty reply from server\n' >&2
    printf '000'
    exit 52
    ;;
  curl_18_token_response:token)
    body='{"token":"TRUNCATED_INSTALLATION_TOKEN_SENTINEL"}'
    [[ -z "${header_file}" ]] || printf 'HTTP/2 200 mock\r\n\r\n' > "${header_file}"
    printf '%s' "${body}" > "${output_file}"
    printf 'curl: (18) end of response with 12 bytes missing\n' >&2
    printf '200'
    exit 18
    ;;
esac

[[ -z "${header_file}" ]] || printf '%b\r\n' "${headers}" > "${header_file}"
printf '%s' "${body}" > "${output_file}"
printf '%s' "${status}"
EOF

  cat > "${mock_dir}/git" <<'EOF'
#!/bin/bash
set -o nounset
set -o errexit

printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/git-arguments"
while [[ "${1:-}" == "-c" ]]; do
  shift 2
done
subcommand="${1:-}"
if [[ "${subcommand}" == "clone" ]]; then
  count_file="${MOCK_STATE_DIR}/git-clone-count"
  count=0
  [[ ! -f "${count_file}" ]] || count=$(cat "${count_file}")
  count=$((count + 1))
  printf '%s' "${count}" > "${count_file}"

  case "${MOCK_SCENARIO}" in
    git_transient)
      if (( count == 1 )); then
        mkdir -p repo
        touch repo/partial-clone
        echo "fatal: unable to access public remote: Could not resolve host" >&2
        exit 128
      fi
      ;;
    git_transient_persistent)
      mkdir -p repo
      touch repo/partial-clone
      echo "fatal: unable to access public remote: Could not resolve host" >&2
      exit 128
      ;;
    git_permanent)
      echo "fatal: Authentication failed for 'https://x-access-token:INSTALLATION_TOKEN_SECRET@github.com/example/downstream'" >&2
      exit 128
      ;;
  esac

  if [[ -e repo/partial-clone ]]; then
    touch "${MOCK_STATE_DIR}/clone-cleanup-failed"
  fi
  mkdir -p repo/openshift/hack
  printf '#!/bin/bash\nexit 0\n' > repo/openshift/hack/update-tests-annotation.sh
  printf '#!/bin/bash\nexit 0\n' > repo/openshift/hack/validate-test-lists.sh
  chmod +x repo/openshift/hack/*.sh
  exit 0
fi

if [[ "${subcommand}" == "rev-list" ]]; then
  printf '2\n'
  exit 0
fi

if [[ "${subcommand}" == "push" ]]; then
  {
    printf 'count=%s\n' "${GIT_CONFIG_COUNT:-}"
    printf 'key=%s\n' "${GIT_CONFIG_KEY_0:-}"
    printf 'value=%s\n' "${GIT_CONFIG_VALUE_0:-}"
  } > "${MOCK_STATE_DIR}/git-push-auth-config"
  count=0
  [[ ! -f "${MOCK_STATE_DIR}/git-push-count" ]] || count=$(cat "${MOCK_STATE_DIR}/git-push-count")
  printf '%s' "$((count + 1))" > "${MOCK_STATE_DIR}/git-push-count"
fi

exit 0
EOF

  chmod +x "${mock_dir}"/*
}

run_script() {
  local scenario="$1" case_dir="$2" trace="${3:-false}"
  local mock_dir="${case_dir}/bin"
  local -a trace_args=()
  local -a budget_env=()
  mkdir -p "${case_dir}/state" "${case_dir}/tmp"
  make_mocks "${mock_dir}"
  printf '%s' 'PRIVATE_KEY_MATERIAL_SECRET' > "${case_dir}/private-key"
  [[ "${trace}" != "true" ]] || trace_args=(-x)
  if [[ "${scenario}" == "deadline_exhausted" ]]; then
    budget_env=(
      STEP_TIMEOUT_SECONDS=8
      WORKFLOW_SHUTDOWN_RESERVE_SECONDS=2
      WORKFLOW_FINALIZATION_RESERVE_SECONDS=3
      RETRY_INITIAL_DELAY_SECONDS=3
      GIT_COMMAND_TIMEOUT_SECONDS=1
      GIT_KILL_AFTER_SECONDS=0
    )
  elif [[ "${scenario}" == rate_limit_403_retry_after_* ]]; then
    budget_env=(
      STEP_TIMEOUT_SECONDS=10
      WORKFLOW_SHUTDOWN_RESERVE_SECONDS=2
      WORKFLOW_FINALIZATION_RESERVE_SECONDS=3
    )
  fi

  env \
    "${budget_env[@]}" \
    PATH="${mock_dir}:${PATH}" \
    TMPDIR="${case_dir}/tmp" \
    MOCK_SCENARIO="${scenario}" \
    MOCK_STATE_DIR="${case_dir}/state" \
    DEFAULT_BRANCH=main \
    UPSTREAM_BRANCH=main \
    UPSTREAM_REPO=example/upstream \
    DOWNSTREAM_REPO=example/downstream \
    MIN_COMMITS=1 \
    RELEASE=4.22 \
    GITHUB_APP_ID=123 \
    GITHUB_APP_PRIVATE_KEY_FILE="${case_dir}/private-key" \
    bash "${trace_args[@]}" "${COMMAND_SCRIPT}" > "${case_dir}/output.log" 2>&1
}

assert_no_secrets() {
  local log="$1"
  assert_not_contains "${log}" 'TOKEN_AUTH_ARGV_SENTINEL'
  assert_not_contains "${log}" 'PRIVATE_KEY_MATERIAL_SECRET'
  assert_not_contains "${log}" 'BASIC_HEADER_SECRET'
  assert_not_contains "${log}" 'BEARER_AUTH_ARGV_SENTINEL'
  assert_not_contains "${log}" 'SIGNATURE_SECRET'
  assert_not_contains "${log}" 'x-access-token:'
  assert_not_contains "${log}" 'Authorization: Bearer'
  assert_not_contains "${log}" 'Authorization: token'
  assert_not_contains "${log}" 'Authorization: Basic'
}

assert_auth_files_removed() {
  local paths_file="$1" path found=false
  [[ -s "${paths_file}" ]] || fail "no curl authentication header files were observed"
  while IFS= read -r path; do
    found=true
    [[ ! -e "${path}" ]] || fail "curl authentication header file was not removed: ${path}"
  done < "${paths_file}"
  [[ "${found}" == "true" ]] || fail "no curl authentication header file paths were recorded"
}

test_default_deadline_bounds() {
  # shellcheck disable=SC2016 # Match literal parameter expansions in the command script.
  assert_contains "${COMMAND_SCRIPT}" 'STEP_TIMEOUT_SECONDS=${STEP_TIMEOUT_SECONDS:-900}'
  # shellcheck disable=SC2016 # Match literal parameter expansions in the command script.
  assert_contains "${COMMAND_SCRIPT}" 'WORKFLOW_SHUTDOWN_RESERVE_SECONDS=${WORKFLOW_SHUTDOWN_RESERVE_SECONDS:-60}'
  # shellcheck disable=SC2016 # Match literal parameter expansions in the command script.
  assert_contains "${COMMAND_SCRIPT}" 'WORKFLOW_FINALIZATION_RESERVE_SECONDS=${WORKFLOW_FINALIZATION_RESERVE_SECONDS:-240}'
  assert_contains "${REF_FILE}" 'timeout: 15m0s'
}

test_auth_headers_use_protected_non_argv_files() {
  local case_dir="${TEST_ROOT}/auth-argv"
  local mode
  mkdir -p "${case_dir}"
  run_script auth_argv "${case_dir}" || fail "non-argv authentication case failed"

  assert_contains "${case_dir}/output.log" "Merge succeeded; PR #77 created"
  assert_contains "${case_dir}/state/curl-received-headers" \
    "Authorization: Bearer BEARER_AUTH_ARGV_SENTINEL.BEARER_AUTH_ARGV_SENTINEL.BEARER_AUTH_ARGV_SENTINEL"
  assert_contains "${case_dir}/state/curl-received-headers" \
    "Authorization: token TOKEN_AUTH_ARGV_SENTINEL"
  assert_contains "${case_dir}/state/curl-received-headers" "Accept: application/vnd.github+json"
  assert_contains "${case_dir}/state/curl-received-headers" "Content-Type: application/json"
  assert_contains "${case_dir}/state/curl-argv-inspections" "safe"
  assert_not_contains "${case_dir}/state/curl-argv" "AUTH_ARGV_SENTINEL"
  assert_not_contains "${case_dir}/state/curl-argv" "Authorization:"
  while IFS= read -r mode; do
    [[ "${mode}" == "600" ]] || fail "curl authentication header file mode was ${mode}, expected 600"
  done < "${case_dir}/state/curl-auth-header-modes"
  assert_auth_files_removed "${case_dir}/state/curl-auth-header-paths"
  assert_no_secrets "${case_dir}/output.log"
}

test_hostile_curlrc_cannot_trace_authorization() {
  local case_dir="${TEST_ROOT}/hostile-curlrc"
  local port_file deadline output_file
  local sentinel='HOSTILE_CURLRC_AUTHORIZATION_SENTINEL'
  mkdir -p "${case_dir}/curl-home" "${case_dir}/tmp"
  printf 'trace-ascii=-\n' > "${case_dir}/curl-home/.curlrc"
  port_file="${case_dir}/server.port"

  # The step-registry ShellCheck image includes Perl and IO::Socket::INET, but
  # not the OpenSSL CLI. Bind port zero so the kernel selects an
  # unused localhost port, publish it, serve exactly one response, and log no
  # request headers (which intentionally include the sentinel credential).
  perl -MIO::Socket::INET -e '
    use strict;
    use warnings;
    my ($port_file) = @ARGV;
    my $server = IO::Socket::INET->new(
      LocalAddr => "127.0.0.1",
      LocalPort => 0,
      Listen => 1,
      Proto => "tcp",
      ReuseAddr => 1,
    ) or die "listen: $!\n";
    open my $port, ">", $port_file or die "open port file: $!\n";
    print {$port} $server->sockport;
    close $port or die "close port file: $!\n";
    my $client = $server->accept or die "accept: $!\n";
    while (my $line = <$client>) {
      last if $line eq "\r\n" || $line eq "\n";
    }
    my $body = "localhost-ok\n";
    print {$client} "HTTP/1.1 200 OK\r\n",
                    "Content-Length: ", length($body), "\r\n",
                    "Connection: close\r\n\r\n", $body;
    close $client or die "close client: $!\n";
    close $server or die "close server: $!\n";
  ' "${port_file}" >"${case_dir}/server.log" 2>&1 &
  LOCALHOST_SERVER_PID=$!

  for _ in {1..100}; do
    [[ -s "${port_file}" ]] && break
    kill -0 "${LOCALHOST_SERVER_PID}" 2>/dev/null || fail "localhost HTTP server exited before publishing its port"
    sleep 0.01
  done
  if [[ ! -s "${port_file}" ]]; then
    fail "localhost HTTP server did not publish its port"
  fi

  output_file="${case_dir}/output.log"
  deadline=$(( $(cut -d. -f1 /proc/uptime) + 30 ))
  if ! CURL_HOME="${case_dir}/curl-home" TMPDIR="${case_dir}/tmp" \
    bash -c '
      source <(awk '\''/^is_transient_git_error\(\)/ { exit } { print }'\'' "$1")
      github_api_request "hostile curlrc regression" "$2" Bearer "$3" "$4"
    ' _ "${COMMAND_SCRIPT}" "${deadline}" "${sentinel}" \
      "http://127.0.0.1:$(cat "${port_file}")/" >"${output_file}" 2>&1; then
    fail "production helper failed with hostile curlrc"
  fi
  wait "${LOCALHOST_SERVER_PID}" || fail "localhost HTTP server failed"
  LOCALHOST_SERVER_PID=""

  assert_contains "${output_file}" "localhost-ok"
  assert_not_contains "${output_file}" "${sentinel}"
  assert_not_contains "${output_file}" "Authorization:"
  assert_not_contains "${case_dir}/server.log" "${sentinel}"
  assert_not_contains "${case_dir}/server.log" "Authorization:"
  [[ -z "$(find "${case_dir}/tmp" -mindepth 1 -print -quit)" ]] || \
    fail "production helper left temporary files behind"
  rm -f "${case_dir}/curl-home/.curlrc" "${port_file}"
  rmdir "${case_dir}/curl-home" "${case_dir}/tmp"
}

test_sensitive_token_response_body_is_never_logged() {
  local case_dir="${TEST_ROOT}/sensitive-token-response"
  local rc
  mkdir -p "${case_dir}"
  set +e
  run_script curl_18_token_response "${case_dir}"
  rc=$?
  set -e

  assert_status "${rc}" 18 "truncated installation-token response"
  assert_count "${case_dir}/state/curl-token-count" 1
  assert_contains "${case_dir}/output.log" \
    "create installation token' failed with curl exit 18 (HTTP 200)"
  assert_contains "${case_dir}/output.log" \
    "GitHub response body suppressed because it may contain credentials"
  assert_contains "${case_dir}/output.log" "curl: (18) end of response"
  assert_not_contains "${case_dir}/output.log" "TRUNCATED_INSTALLATION_TOKEN_SENTINEL"
  assert_auth_files_removed "${case_dir}/state/curl-auth-header-paths"
  [[ -z "$(find "${case_dir}/tmp" -mindepth 1 -print -quit)" ]] || \
    fail "sensitive-response failure left temporary files behind"
}

test_http_transient_then_recovers() {
  local case_dir="${TEST_ROOT}/http-transient"
  mkdir -p "${case_dir}"
  run_script http_transient "${case_dir}" || fail "HTTP transient case did not recover"
  assert_count "${case_dir}/state/curl-installation-count" 2
  assert_contains "${case_dir}/output.log" "returned transient HTTP 503 (attempt 1/3); retrying in 2s"
  assert_contains "${case_dir}/output.log" "Found open downstream-merge PR(s): 42"
  assert_no_secrets "${case_dir}/output.log"
}

test_rate_limit_403_honors_retry_after() {
  local case_dir="${TEST_ROOT}/rate-limit-403"
  mkdir -p "${case_dir}"
  run_script rate_limit_403 "${case_dir}" || fail "rate-limited 403 did not recover"
  assert_count "${case_dir}/state/curl-installation-count" 2
  assert_contains "${case_dir}/output.log" "returned transient HTTP 403 (attempt 1/3); retrying in 0s"
  [[ "$(cat "${case_dir}/state/sleep-delays")" == "0" ]] || fail "Retry-After: 0 was not honored"
}

test_rate_limit_403_honors_reset() {
  local case_dir="${TEST_ROOT}/rate-limit-403-reset"
  mkdir -p "${case_dir}"
  run_script rate_limit_403_reset "${case_dir}" || fail "rate-limited 403 reset did not recover"
  assert_count "${case_dir}/state/curl-installation-count" 2
  assert_contains "${case_dir}/output.log" "returned transient HTTP 403 (attempt 1/3); retrying in 0s"
  [[ "$(cat "${case_dir}/state/sleep-delays")" == "0" ]] || fail "X-RateLimit-Reset was not honored"
}

test_rate_limit_403_honors_http_date() {
  local case_dir="${TEST_ROOT}/rate-limit-403-http-date"
  mkdir -p "${case_dir}"
  run_script rate_limit_403_http_date "${case_dir}" || fail "rate-limited 403 HTTP-date did not recover"
  assert_count "${case_dir}/state/curl-installation-count" 2
  assert_contains "${case_dir}/output.log" "returned transient HTTP 403 (attempt 1/3); retrying in 0s"
  [[ "$(cat "${case_dir}/state/sleep-delays")" == "0" ]] || fail "HTTP-date Retry-After was not honored"
}

test_rate_limit_retry_after_exceeding_deadline() {
  local scenario="$1" expected_delay="$2"
  local case_dir="${TEST_ROOT}/${scenario}"
  local rc
  mkdir -p "${case_dir}"
  set +e
  run_script "${scenario}" "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 124 "${scenario}"
  assert_count "${case_dir}/state/curl-installation-count" 1
  [[ ! -e "${case_dir}/state/sleep-delays" ]] || fail "${scenario} invoked sleep"
  assert_contains "${case_dir}/output.log" "retrying in ${expected_delay}s"
  assert_contains "${case_dir}/output.log" "cannot honor a ${expected_delay}s retry delay"
  assert_matches "${case_dir}/output.log" 'with only [0-7]s left before the shared deadline'
  assert_not_contains "${case_dir}/output.log" "value too great for base"
  assert_not_contains "${case_dir}/output.log" "invalid octal number"
  assert_not_contains "${case_dir}/output.log" "arithmetic syntax error"
  assert_auth_files_removed "${case_dir}/state/curl-auth-header-paths"
}

test_plain_403_is_permanent() {
  local case_dir="${TEST_ROOT}/plain-403"
  local rc
  mkdir -p "${case_dir}"
  set +e
  run_script http_403_permanent "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 22 "plain 403"
  assert_count "${case_dir}/state/curl-installation-count" 1
  assert_contains "${case_dir}/output.log" "failed with HTTP 403; not retrying"
  assert_not_contains "${case_dir}/output.log" "retrying in"
  assert_auth_files_removed "${case_dir}/state/curl-auth-header-paths"
}

test_persistent_http_503_exhausts() {
  local case_dir="${TEST_ROOT}/http-503-persistent"
  local rc
  mkdir -p "${case_dir}"
  set +e
  run_script http_503_persistent "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 22 "persistent HTTP 503"
  assert_count "${case_dir}/state/curl-installation-count" 3
  assert_backoffs "${case_dir}/state/sleep-delays"
  assert_contains "${case_dir}/output.log" "failed after 3 attempts (last HTTP 503)"
  assert_auth_files_removed "${case_dir}/state/curl-auth-header-paths"
}

test_persistent_curl_transport_exhausts() {
  local case_dir="${TEST_ROOT}/curl-28-persistent"
  local rc
  mkdir -p "${case_dir}"
  set +e
  run_script curl_28_persistent "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 28 "persistent curl transport failure"
  assert_count "${case_dir}/state/curl-installation-count" 3
  assert_backoffs "${case_dir}/state/sleep-delays"
  assert_contains "${case_dir}/output.log" "failed after 3 attempts (last curl exit 28)"
  assert_contains "${case_dir}/output.log" "Operation timed out"
  assert_auth_files_removed "${case_dir}/state/curl-auth-header-paths"
}

test_git_transient_then_recovers() {
  local case_dir="${TEST_ROOT}/git-transient"
  mkdir -p "${case_dir}"
  run_script git_transient "${case_dir}" || fail "Git transient case did not recover"
  assert_count "${case_dir}/state/git-clone-count" 2
  [[ ! -e "${case_dir}/state/clone-cleanup-failed" ]] || fail "partial clone was not cleaned before retry"
  assert_contains "${case_dir}/output.log" "Git operation 'clone downstream repository' had a transient failure (attempt 1/3); retrying in 2s"
  assert_no_secrets "${case_dir}/output.log"
}

test_persistent_git_transport_exhausts() {
  local case_dir="${TEST_ROOT}/git-persistent"
  local rc
  mkdir -p "${case_dir}"
  set +e
  run_script git_transient_persistent "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 128 "persistent Git transport failure"
  assert_count "${case_dir}/state/git-clone-count" 3
  assert_backoffs "${case_dir}/state/sleep-delays"
  assert_contains "${case_dir}/output.log" "failed after 3 attempts (last exit 128)"
}

test_timeout_exit_exhausts() {
  local exit_code="$1"
  local case_dir="${TEST_ROOT}/timeout-${exit_code}"
  local rc
  mkdir -p "${case_dir}"
  set +e
  run_script "timeout_${exit_code}_persistent" "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" "${exit_code}" "persistent timeout ${exit_code}"
  assert_count "${case_dir}/state/timeout-count" 3
  assert_backoffs "${case_dir}/state/sleep-delays"
  assert_contains "${case_dir}/output.log" "failed after 3 attempts (last exit ${exit_code})"
  assert_contains "${case_dir}/state/timeout-arguments" "--kill-after=5s 120s"
  assert_not_contains "${case_dir}/state/timeout-arguments" "--foreground"
}

test_shared_deadline_stops_retries() {
  local case_dir="${TEST_ROOT}/deadline-exhausted"
  local rc
  mkdir -p "${case_dir}"
  set +e
  run_script deadline_exhausted "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 124 "shared retry deadline"
  assert_count "${case_dir}/state/timeout-count" 1
  assert_contains "${case_dir}/output.log" "cannot honor a 3s retry delay"
}

test_permanent_failures_are_not_retried() {
  local scenario case_dir expected_status message
  for scenario in http_permanent git_permanent; do
    case_dir="${TEST_ROOT}/${scenario}"
    mkdir -p "${case_dir}"
    set +e
    run_script "${scenario}" "${case_dir}"
    expected_status=$?
    set -e
    if [[ "${scenario}" == "http_permanent" ]]; then
      assert_status "${expected_status}" 22 "permanent HTTP authentication failure"
      assert_count "${case_dir}/state/curl-installation-count" 1
      message="failed with HTTP 401; not retrying"
      assert_contains "${case_dir}/output.log" "Bad credentials"
    else
      assert_status "${expected_status}" 128 "permanent Git authentication failure"
      assert_count "${case_dir}/state/git-clone-count" 1
      message="failed with exit 128; not retrying"
      assert_contains "${case_dir}/output.log" "Authentication failed"
    fi
    assert_contains "${case_dir}/output.log" "${message}"
    assert_not_contains "${case_dir}/output.log" "retrying in"
    assert_no_secrets "${case_dir}/output.log"
  done
}

test_ambiguous_post_is_not_replayed() {
  local case_dir="${TEST_ROOT}/post-ambiguous"
  local rc
  mkdir -p "${case_dir}"
  set +e
  run_script post_ambiguous "${case_dir}"
  rc=$?
  set -e
  assert_status "${rc}" 52 "ambiguous create-PR POST"
  assert_count "${case_dir}/state/curl-create-pr-count" 1
  [[ "$(wc -l < "${case_dir}/state/mutations")" == "1" ]] || fail "expected one committed mutation"
  assert_contains "${case_dir}/output.log" "POST requests are not retried because the result may be ambiguous"
  assert_not_contains "${case_dir}/output.log" "create downstream merge pull request' had a transient"
  assert_auth_files_removed "${case_dir}/state/curl-auth-header-paths"
}

test_xtrace_never_exposes_credentials() {
  local case_dir="${TEST_ROOT}/xtrace"
  mkdir -p "${case_dir}"
  run_script xtrace "${case_dir}" true || fail "xtrace full-path case failed"
  assert_contains "${case_dir}/output.log" "Merge succeeded; PR #77 created"
  assert_count "${case_dir}/state/git-push-count" 1
  assert_contains "${case_dir}/state/git-push-auth-config" "count=1"
  assert_contains "${case_dir}/state/git-push-auth-config" "key=http.extraHeader"
  assert_contains "${case_dir}/state/git-push-auth-config" "value=Authorization: Basic BASIC_HEADER_SECRET"
  assert_not_contains "${case_dir}/state/git-arguments" "http.extraHeader"
  assert_no_secrets "${case_dir}/state/git-arguments"
  assert_no_secrets "${case_dir}/state/timeout-arguments"
  assert_no_secrets "${case_dir}/output.log"
}

test_default_deadline_bounds
test_auth_headers_use_protected_non_argv_files
test_hostile_curlrc_cannot_trace_authorization
test_sensitive_token_response_body_is_never_logged
test_http_transient_then_recovers
test_rate_limit_403_honors_retry_after
test_rate_limit_403_honors_reset
test_rate_limit_403_honors_http_date
test_rate_limit_retry_after_exceeding_deadline rate_limit_403_retry_after_08 8
test_rate_limit_retry_after_exceeding_deadline rate_limit_403_retry_after_0008 8
test_rate_limit_retry_after_exceeding_deadline rate_limit_403_retry_after_oversized 999999999999999999
test_plain_403_is_permanent
test_persistent_http_503_exhausts
test_persistent_curl_transport_exhausts
test_git_transient_then_recovers
test_persistent_git_transport_exhausts
test_timeout_exit_exhausts 124
test_timeout_exit_exhausts 137
test_shared_deadline_stops_retries
test_permanent_failures_are_not_retried
test_ambiguous_post_is_not_replayed
test_xtrace_never_exposes_credentials

echo "PASS: github downstream sync retry tests"
