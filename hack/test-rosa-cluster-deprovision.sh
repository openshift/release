#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/ci-operator/step-registry/rosa/cluster/deprovision/rosa-cluster-deprovision-commands.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "${test_dir}"' EXIT
mkdir -p "${test_dir}/bin" "${test_dir}/profile"
touch "${test_dir}/profile/.awscred"
printf 'mock-token' > "${test_dir}/profile/ocm-token"

cat > "${test_dir}/bin/rosa" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "${MOCK_CALLS}"
case "$1 $2" in
  'login --env') exit 0 ;;
  'delete cluster') [[ "${SCENARIO}" != delete-failure* ]] || exit 7 ;;
  'describe cluster')
    case "${SCENARIO}" in
      success|success-no-sts|role-failure) exit 0 ;;
      error) echo '{"state":"error"}' ;;
      *) echo '{"state":"uninstalling"}' ;;
    esac ;;
  'logs uninstall')
    [[ "$*" == 'logs uninstall --cluster=mock-cluster --tail=2000' ]] || exit 9
    case "${SCENARIO}" in
      *logs-failure) echo 'mock-sensitive-stderr' >&2; echo 'AccessDenied mock-sensitive-payload'; exit 8 ;;
      hang) trap '' TERM; exec /usr/bin/sleep 30 ;;
      no-matches) echo 'unrecognized mock-sensitive-payload' ;;
      *) printf 'AccessDenied mock-sensitive-payload\nDependencyViolation mock-sensitive-payload\nother mock-sensitive-payload\n' ;;
    esac ;;
  'delete operator-roles') [[ "${SCENARIO}" != role-failure ]] || exit 6 ;;
  'delete oidc-provider') exit 0 ;;
  *) exit 9 ;;
esac
MOCK

cat > "${test_dir}/bin/timeout" <<'MOCK'
#!/bin/bash
[[ "$1 $2" == '--kill-after=5s 60s' ]] || exit 9
shift 2
exec /usr/bin/timeout --kill-after=0.1s 0.1s "$@"
MOCK

cat > "${test_dir}/bin/sleep" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "${test_dir}/bin/"*

assert_no_match() {
  if grep -q "$1" "$2"; then
    echo "FAIL: unexpected matching output" >&2
    return 1
  else
    [[ "$?" == 1 ]]
  fi
}

for scenario in timeout error logs-failure hang no-matches delete-failure delete-failure-logs-failure delete-failure-unwritable-artifacts success success-no-sts role-failure missing-artifacts unwritable-artifacts; do
  scenario_dir="${test_dir}/${scenario}"
  mkdir -p "${scenario_dir}/shared" "${scenario_dir}/artifacts"
  printf 'mock-cluster' > "${scenario_dir}/shared/cluster-id"
  printf '{"timers":{}}' > "${scenario_dir}/shared/cluster-config"
  artifact_dir="${scenario_dir}/artifacts"
  if [[ "${scenario}" == *unwritable-artifacts ]]; then
    mkdir "${artifact_dir}/uninstall-log-summary.txt"
  elif [[ "${scenario}" == missing-artifacts ]]; then
    artifact_dir="${scenario_dir}/absent"
  fi
  destroy_timeout=0
  if [[ "${scenario}" == error || "${scenario}" == success* || "${scenario}" == role-failure ]]; then
    destroy_timeout=3600
  fi
  sts=true
  if [[ "${scenario}" == success-no-sts ]]; then
    sts=false
  fi
  status=0
  /usr/bin/timeout --kill-after=1s 5s env PATH="${test_dir}/bin:${PATH}" SCENARIO="${scenario}" MOCK_CALLS="${scenario_dir}/calls" \
    SHARED_DIR="${scenario_dir}/shared" CLUSTER_PROFILE_DIR="${test_dir}/profile" \
    LEASED_RESOURCE=mock-region OCM_LOGIN_ENV=staging STS="${sts}" DESTROY_TIMEOUT="${destroy_timeout}" \
    ARTIFACT_DIR="${artifact_dir}" bash "${script}" > "${scenario_dir}/output" 2>&1 || status=$?
  expected_status=1
  case "${scenario}" in
    success*) expected_status=0 ;;
    delete-failure*) expected_status=7 ;;
    role-failure) expected_status=6 ;;
  esac
  [[ "${status}" == "${expected_status}" ]]
  [[ $(grep -c '^delete cluster ' "${scenario_dir}/calls") == 1 ]]
  if [[ "${scenario}" == success* ]]; then
    assert_no_match '^logs uninstall ' "${scenario_dir}/calls"
    jq -e '.timers.destroy != null' "${scenario_dir}/shared/cluster-config" > /dev/null
    if [[ "${sts}" == true ]]; then
      grep -qx 'delete operator-roles -c mock-cluster -y -m auto' "${scenario_dir}/calls"
      grep -qx 'delete oidc-provider -c mock-cluster -y -m auto' "${scenario_dir}/calls"
      jq -e '.timers.sts_destroy != null' "${scenario_dir}/shared/cluster-config" > /dev/null
    else
      assert_no_match '^delete operator-roles\|^delete oidc-provider' "${scenario_dir}/calls"
      jq -e '.timers.sts_destroy == null' "${scenario_dir}/shared/cluster-config" > /dev/null
    fi
    [[ ! -e "${artifact_dir}/uninstall-log-summary.txt" ]]
  elif [[ "${scenario}" != missing-artifacts && "${scenario}" != *unwritable-artifacts ]]; then
    [[ $(grep -c '^logs uninstall ' "${scenario_dir}/calls") == 1 ]]
    summary="${artifact_dir}/uninstall-log-summary.txt"
    case "${scenario}" in
      *logs-failure) grep -qx 'collection_exit_code=8' "${summary}" ;;
      hang) grep -Eq '^collection_exit_code=(124|137)$' "${summary}" ;;
      no-matches) grep -qx 'collection_exit_code=0' "${summary}"; grep -qx 'log_lines=1' "${summary}"; grep -qx 'AccessDenied=0' "${summary}" ;;
      *) grep -qx 'collection_exit_code=0' "${summary}"; grep -qx 'AccessDenied=1' "${summary}"; grep -qx 'DependencyViolation=1' "${summary}" ;;
    esac
    assert_no_match 'mock-sensitive\|mock-cluster\|mock-token\|mock-region' "${summary}"
    [[ $(wc -l < "${summary}") == 9 ]]
  fi
  if [[ "${scenario}" != success* && "${scenario}" != role-failure ]]; then
    assert_no_match '^delete operator-roles\|^delete oidc-provider' "${scenario_dir}/calls"
  fi
  assert_no_match 'mock-sensitive' "${scenario_dir}/output"
  assert_no_match '^+' "${scenario_dir}/output"
  printf 'PASS: %s\n' "${scenario}"
done
