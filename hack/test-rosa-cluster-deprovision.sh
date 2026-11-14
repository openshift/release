#!/bin/bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/ci-operator/step-registry/rosa/cluster/deprovision/rosa-cluster-deprovision-commands.sh"
workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT

# Report the failing scenario with its captured step output.
fail() {
  echo "FAIL: ${scenario}: $*" >&2
  cat "${TEST_DIR}/output" >&2
  exit 1
}

for scenario in timeout error logs-fail logs-hang logs-sensitive logs-sensitive-fail describe-fail unknown-state \
  success-sts success-nonsts success-after-poll no-cluster no-artifacts empty-artifacts \
  bad-artifacts summary-fail legacy-log-path term; do
  export TEST_DIR="${workdir}/${scenario}"
  export SCENARIO="${scenario}"
  export SHARED_DIR="${TEST_DIR}/shared"
  export CLUSTER_PROFILE_DIR="${TEST_DIR}/profile"
  export ARTIFACT_DIR="${TEST_DIR}/artifacts"
  export LEASED_RESOURCE=mock-region OCM_LOGIN_ENV=mock STS=true DESTROY_TIMEOUT=10
  mkdir -p "${TEST_DIR}/bin" "${SHARED_DIR}" "${CLUSTER_PROFILE_DIR}" "${ARTIFACT_DIR}"
  : > "${CLUSTER_PROFILE_DIR}/.awscred"
  printf 'mock-token' > "${CLUSTER_PROFILE_DIR}/ocm-token"
  printf 'mock-cluster' > "${SHARED_DIR}/cluster-id"
  printf '{"timers":{}}\n' > "${SHARED_DIR}/cluster-config"
  printf '100\n' > "${TEST_DIR}/clock"
  : > "${TEST_DIR}/calls"

  cat > "${TEST_DIR}/bin/rosa" <<'MOCK'
#!/bin/bash
set -euo pipefail
case "$1 $2" in
  'login --env') echo login >> "${TEST_DIR}/calls" ;;
  'delete cluster'|'delete operator-roles'|'delete oidc-provider')
    printf '%s\n' "$*" >> "${TEST_DIR}/calls"
    ;;
  'describe cluster')
    echo describe >> "${TEST_DIR}/calls"
    echo 'mock-auth-stderr-not-for-artifacts' >&2
    case "${SCENARIO}" in
      success-sts|success-nonsts) exit 1 ;;
      success-after-poll)
        if [[ -f "${TEST_DIR}/described" ]]; then exit 1; fi
        touch "${TEST_DIR}/described"
        state=uninstalling
        ;;
      error|logs-fail|logs-hang|logs-sensitive|logs-sensitive-fail|summary-fail|legacy-log-path|term) state=error ;;
      unknown-state) state=mock-sensitive-state ;;
      *) state=uninstalling ;;
    esac
    printf '{"state":"%s","credentials":"mock-private-json-not-for-artifacts"}\n' "${state}"
    if [[ "${SCENARIO}" == describe-fail ]]; then exit 23; fi
    ;;
  'logs uninstall')
    printf '%s\n' "$*" >> "${TEST_DIR}/calls"
    echo 'mock-auth-log-stderr-not-for-artifacts' >&2
    echo 'mock-untrusted-uninstall-log'
    if [[ "${SCENARIO}" == logs-sensitive* ]]; then
      cat "${TEST_DIR}/untrusted-payload"
      cat "${TEST_DIR}/untrusted-payload" >&2
      printf '\000\033[31mmock-untrusted-control-payload\n'
      printf '\000\033[31mmock-untrusted-control-payload\n' >&2
    fi
    case "${SCENARIO}" in
      logs-fail|logs-sensitive-fail) exit 42 ;;
      logs-hang|term)
        echo "$$" > "${TEST_DIR}/logs-pid"
        trap '' TERM
        /bin/sleep 120 &
        descendant_pid=$!
        echo "${descendant_pid}" > "${TEST_DIR}/logs-descendant-pid"
        ps -o pgid= -p "$$" > "${TEST_DIR}/logs-pgid"
        ps -o pgid= -p "${descendant_pid}" > "${TEST_DIR}/logs-descendant-pgid"
        touch "${TEST_DIR}/logs-ready"
        wait "${descendant_pid}"
        ;;
    esac
    ;;
  *) echo 'Unexpected rosa invocation' >&2; exit 99 ;;
esac
MOCK
  cat > "${TEST_DIR}/bin/date" <<'MOCK'
#!/bin/bash
set -euo pipefail
current=$(cat "${TEST_DIR}/clock")
printf '%s\n' "$((current + 10))" > "${TEST_DIR}/clock"
printf '%s\n' "${current}"
MOCK
  cat > "${TEST_DIR}/bin/sleep" <<'MOCK'
#!/bin/bash
printf 'sleep %s\n' "$*" >> "${TEST_DIR}/calls"
MOCK
  chmod +x "${TEST_DIR}/bin/"*

  cat > "${TEST_DIR}/untrusted-payload" <<'PAYLOAD'
mock-untrusted-credential password=synthetic-password
mock-untrusted-token Authorization: Bearer synthetic-token
mock-untrusted-session session_id=synthetic-session
mock-untrusted-pii synthetic-person@example.invalid
mock-untrusted-host https://synthetic-host.internal.invalid
{"state":"error","reason":"mock-untrusted-json","token":"synthetic-token"}
reason=mock-untrusted-summary-injection
uninstall_logs_exit_code=mock-untrusted-exit-injection
PAYLOAD

  case "${scenario}" in
    error|logs-fail|logs-hang|logs-sensitive|logs-sensitive-fail|summary-fail|legacy-log-path|term|success-*) DESTROY_TIMEOUT=3600 ;;
  esac
  case "${scenario}" in
    success-nonsts) STS=false ;;
    no-cluster) rm "${SHARED_DIR}/cluster-id" ;;
    no-artifacts) unset ARTIFACT_DIR ;;
    empty-artifacts) ARTIFACT_DIR='' ;;
    bad-artifacts) rmdir "${ARTIFACT_DIR}"; touch "${ARTIFACT_DIR}" ;;
    summary-fail) mkdir "${ARTIFACT_DIR}/rosa-deprovision-failure.txt" ;;
    legacy-log-path) mkdir "${ARTIFACT_DIR}/rosa-uninstall.log" ;;
  esac

  started=${SECONDS}
  status=0
  if [[ "${scenario}" == term ]]; then
    PATH="${TEST_DIR}/bin:${PATH}" bash "${script}" > "${TEST_DIR}/output" 2>&1 &
    step_pid=$!
    for ((attempt=0; attempt<100; attempt++)); do
      if [[ -f "${TEST_DIR}/logs-ready" ]]; then break; fi
      /bin/sleep 0.05
    done
    if [[ ! -f "${TEST_DIR}/logs-ready" ]]; then
      kill -TERM "${step_pid}" || true
      wait "${step_pid}" || true
      fail 'diagnostics did not start'
    fi
    kill -TERM "${step_pid}"
    wait "${step_pid}" || status=$?
  else
    PATH="${TEST_DIR}/bin:${PATH}" timeout --kill-after=2s 45s bash "${script}" \
      > "${TEST_DIR}/output" 2>&1 || status=$?
  fi
  elapsed=$((SECONDS - started))

  expected=1
  case "${scenario}" in success-*|no-cluster) expected=0 ;; esac
  [[ "${status}" -eq "${expected}" ]] || fail "expected exit ${expected}, got ${status}"
  if grep -aREq 'mock-(auth|private-json|untrusted)' "${TEST_DIR}/artifacts" "${TEST_DIR}/output"; then
    fail 'diagnostics disclosed arbitrary CLI stdout, stderr or describe JSON'
  fi
  [[ ! -f "${TEST_DIR}/artifacts/rosa-uninstall.log" ]] || fail 'raw uninstall log artifact created'

  case "${scenario}" in
    success-*)
      [[ -z "$(ls -A "${ARTIFACT_DIR}")" ]] || fail 'success collected failure artifacts'
      if [[ "${STS}" == true ]]; then
        printf 'login\ndelete cluster -c mock-cluster -y\ndescribe\n' > "${TEST_DIR}/expected"
        if [[ "${scenario}" == success-after-poll ]]; then
          printf 'sleep 60\ndescribe\n' >> "${TEST_DIR}/expected"
        fi
        printf 'delete operator-roles -c mock-cluster -y -m auto\ndelete oidc-provider -c mock-cluster -y -m auto\nsleep 120\n' >> "${TEST_DIR}/expected"
        diff -u "${TEST_DIR}/expected" "${TEST_DIR}/calls" || fail 'STS order or polling changed'
        jq -e '.timers.destroy > 0 and .timers.sts_destroy > 0' "${SHARED_DIR}/cluster-config" >/dev/null
      else
        ! grep -Eq 'operator-roles|oidc-provider|logs uninstall' "${TEST_DIR}/calls" || fail 'unexpected cleanup or diagnostics'
        grep -qx 'sleep 120' "${TEST_DIR}/calls" || fail 'success sleep changed'
      fi
      ;;
    no-cluster|no-artifacts|empty-artifacts|bad-artifacts)
      ! grep -q 'logs uninstall' "${TEST_DIR}/calls" || fail 'unexpected log collection'
      ;;
    summary-fail)
      grep -qx 'logs uninstall --cluster mock-cluster --tail=500 --watch' "${TEST_DIR}/calls" || fail 'summary failure suppressed log probe'
      ;;
    *)
      summary="${ARTIFACT_DIR}/rosa-deprovision-failure.txt"
      grep -q '^reason=' "${summary}" || fail 'missing failure summary'
      expected_logs_status=0
      case "${scenario}" in
        logs-fail|logs-sensitive-fail) expected_logs_status=42 ;;
        logs-hang) expected_logs_status=137 ;;
        term) expected_logs_status=143 ;;
      esac
      grep -qx "uninstall_logs_exit_code=${expected_logs_status}" "${summary}" || fail 'missing post-logs status'
      case "${scenario}" in
        timeout|describe-fail|unknown-state)
          grep -qx 'reason=timeout' "${summary}" || fail 'wrong failure reason'
          grep -qx 'elapsed_seconds=10' "${summary}" || fail 'wrong elapsed time'
          grep -qx 'logs uninstall --cluster mock-cluster --tail=500' "${TEST_DIR}/calls" || fail 'expected non-watch log snapshot'
          ;;
        *)
          grep -qx 'reason=error' "${summary}" || fail 'wrong failure reason'
          grep -qx 'logs uninstall --cluster mock-cluster --tail=500 --watch' "${TEST_DIR}/calls" || fail 'error-state logs need watch'
          ;;
      esac
      if [[ "${scenario}" == describe-fail ]]; then
        grep -qx 'describe_pipeline_exit_code=23' "${summary}" || fail 'describe failure status lost'
      fi
      if [[ "${scenario}" == unknown-state ]]; then
        grep -qx 'state=other' "${summary}" || fail 'state not allowlisted'
        ! grep -q 'mock-sensitive-state' "${summary}" || fail 'arbitrary state disclosed'
      fi
      expected_reason=error
      expected_state=error
      expected_describe_status=0
      case "${scenario}" in
        timeout|describe-fail) expected_reason=timeout; expected_state=uninstalling ;;
        unknown-state) expected_reason=timeout; expected_state=other ;;
      esac
      if [[ "${scenario}" == describe-fail ]]; then expected_describe_status=23; fi
      printf 'reason=%s\nstate=%s\nelapsed_seconds=10\ndescribe_pipeline_exit_code=%s\nuninstall_logs_output=omitted_unstructured\nuninstall_logs_exit_code=%s\n' \
        "${expected_reason}" "${expected_state}" "${expected_describe_status}" "${expected_logs_status}" \
        > "${TEST_DIR}/expected-summary"
      diff -u "${TEST_DIR}/expected-summary" "${summary}" || fail 'summary exceeded safe field contract'
      if [[ "${scenario}" == legacy-log-path ]]; then
        [[ -z "$(ls -A "${ARTIFACT_DIR}/rosa-uninstall.log")" ]] || fail 'raw log path was used'
      fi
      if [[ "${scenario}" == logs-hang || "${scenario}" == term ]]; then
        [[ "${elapsed}" -le 40 ]] || fail 'diagnostics exceeded hard bound'
        if [[ "${scenario}" == term ]]; then
          [[ "${elapsed}" -le 10 ]] || fail 'TERM did not stop diagnostic child promptly'
        else
          [[ "${elapsed}" -ge 30 ]] || fail 'timeout did not exercise configured bound'
        fi
        cmp "${TEST_DIR}/logs-pgid" "${TEST_DIR}/logs-descendant-pgid" || fail 'descendant escaped diagnostic process group'
        for pid_file in logs-pid logs-descendant-pid; do
          child_state=$(ps -o stat= -p "$(cat "${TEST_DIR}/${pid_file}")" || true)
          [[ -z "${child_state}" || "${child_state}" == Z* ]] || fail "diagnostic process still running: ${pid_file}"
        done
      fi
      ;;
  esac
  if [[ "${expected}" -eq 1 ]]; then
    ! grep -Eq 'operator-roles|oidc-provider|sleep 120' "${TEST_DIR}/calls" || fail 'failure continued success cleanup'
  fi
  printf 'PASS: %s (exit %s, %ss)\n' "${scenario}" "${status}" "${elapsed}"
done
