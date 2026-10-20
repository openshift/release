#!/bin/bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/ci-operator/step-registry/rosa/cluster/deprovision/rosa-cluster-deprovision-commands.sh"
workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT

fail() {
  echo "FAIL: ${scenario}: $*" >&2
  cat "${TEST_DIR}/output" >&2
  exit 1
}

for scenario in timeout error logs-fail logs-hang describe-fail unknown-state \
  success-sts success-nonsts success-after-poll no-cluster no-artifacts empty-artifacts \
  bad-artifacts summary-fail logfile-fail term; do
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
      error|logs-fail|logs-hang|summary-fail|logfile-fail|term) state=error ;;
      unknown-state) state=mock-sensitive-state ;;
      *) state=uninstalling ;;
    esac
    printf '{"state":"%s","credentials":"mock-private-json-not-for-artifacts"}\n' "${state}"
    if [[ "${SCENARIO}" == describe-fail ]]; then exit 23; fi
    ;;
  'logs uninstall')
    printf '%s\n' "$*" >> "${TEST_DIR}/calls"
    echo 'mock-auth-log-stderr-not-for-artifacts' >&2
    echo 'mock uninstall log'
    case "${SCENARIO}" in
      logs-fail) exit 42 ;;
      logs-hang|term)
        echo "$$" > "${TEST_DIR}/logs-pid"
        trap '' TERM
        /bin/sleep 120
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

  case "${scenario}" in
    error|logs-fail|logs-hang|summary-fail|logfile-fail|term|success-*) DESTROY_TIMEOUT=3600 ;;
  esac
  case "${scenario}" in
    success-nonsts) STS=false ;;
    no-cluster) rm "${SHARED_DIR}/cluster-id" ;;
    no-artifacts) unset ARTIFACT_DIR ;;
    empty-artifacts) ARTIFACT_DIR='' ;;
    bad-artifacts) rmdir "${ARTIFACT_DIR}"; touch "${ARTIFACT_DIR}" ;;
    summary-fail) mkdir "${ARTIFACT_DIR}/rosa-deprovision-failure.txt" ;;
    logfile-fail) mkdir "${ARTIFACT_DIR}/rosa-uninstall.log" ;;
  esac

  started=${SECONDS}
  status=0
  if [[ "${scenario}" == term ]]; then
    PATH="${TEST_DIR}/bin:${PATH}" bash "${script}" > "${TEST_DIR}/output" 2>&1 &
    step_pid=$!
    for ((attempt=0; attempt<100; attempt++)); do
      if [[ -f "${TEST_DIR}/logs-pid" ]]; then break; fi
      /bin/sleep 0.05
    done
    if [[ ! -f "${TEST_DIR}/logs-pid" ]]; then
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
  if grep -REq 'mock-(auth|private-json)' "${TEST_DIR}/artifacts"; then
    fail 'diagnostics disclosed describe JSON or stderr'
  fi

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
      grep -qx 'mock uninstall log' "${ARTIFACT_DIR}/rosa-uninstall.log" || fail 'summary failure suppressed logs'
      ;;
    *)
      summary="${ARTIFACT_DIR}/rosa-deprovision-failure.txt"
      grep -q '^reason=' "${summary}" || fail 'missing failure summary'
      expected_logs_status=0
      case "${scenario}" in
        logs-fail) expected_logs_status=42 ;;
        logs-hang) expected_logs_status=137 ;;
        term) expected_logs_status=143 ;;
        logfile-fail) expected_logs_status=1 ;;
      esac
      grep -qx "uninstall_logs_exit_code=${expected_logs_status}" "${summary}" || fail 'missing post-logs status'
      case "${scenario}" in
        timeout|describe-fail|unknown-state)
          grep -qx 'reason=timeout' "${summary}" || fail 'wrong failure reason'
          grep -qx 'elapsed_seconds=10' "${summary}" || fail 'wrong elapsed time'
          grep -qx 'logs uninstall --cluster mock-cluster --tail=500' "${TEST_DIR}/calls" || fail 'expected non-watch log snapshot'
          ;;
        logfile-fail) ;;
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
      if [[ "${scenario}" == logs-hang || "${scenario}" == term ]]; then
        [[ "${elapsed}" -le 40 ]] || fail 'diagnostics exceeded hard bound'
        if [[ "${scenario}" == term ]]; then
          [[ "${elapsed}" -le 10 ]] || fail 'TERM did not stop diagnostic child promptly'
        else
          [[ "${elapsed}" -ge 30 ]] || fail 'timeout did not exercise configured bound'
        fi
        child_state=$(ps -o stat= -p "$(cat "${TEST_DIR}/logs-pid")" || true)
        [[ -z "${child_state}" || "${child_state}" == Z* ]] || fail 'diagnostic child still running'
        grep -qx 'mock uninstall log' "${ARTIFACT_DIR}/rosa-uninstall.log" || fail 'partial logs lost'
      fi
      ;;
  esac
  if [[ "${expected}" -eq 1 ]]; then
    ! grep -Eq 'operator-roles|oidc-provider|sleep 120' "${TEST_DIR}/calls" || fail 'failure continued success cleanup'
  fi
  printf 'PASS: %s (exit %s, %ss)\n' "${scenario}" "${status}" "${elapsed}"
done
