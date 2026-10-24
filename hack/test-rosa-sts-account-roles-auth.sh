#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "${test_dir}"' EXIT
export test_dir

python3 - "$root" <<'PY'
from pathlib import Path
import sys

base = Path(sys.argv[1]) / 'ci-operator/step-registry/rosa/sts/account-roles'
blocks = []
for operation in ('create', 'delete'):
    source = (base / operation / f'rosa-sts-account-roles-{operation}-commands.sh').read_text()
    blocks.append(source[source.index('auth_diagnostic()'):source.index('\nrosa_login\n')])
assert blocks[0] == blocks[1], 'Inline authentication implementations differ'
PY

rosa() {
  if [[ "$1" != login ]]; then
    printf '%s\n' "$*" >> "${case_dir}/operations"
    case "$1 $2" in
      'whoami --output') printf '{"AWS Account ID":"123456789012"}\n' ;;
      'list account-roles') printf '[{"RoleARN":"arn:aws:iam::123456789012:role/fixture-Installer-Role"}]\n' ;;
      'create account-roles'|'delete account-roles') ;;
      *) return 93 ;;
    esac
    return 0
  fi
  local attempt=0 failure="${scenario}"
  [[ ! -f "${case_dir}/calls" ]] || read -r attempt < "${case_dir}/calls"
  attempt=$((attempt + 1))
  printf '%s\n' "${attempt}" > "${case_dir}/calls"
  jq -e --argjson attempt "${attempt}" 'select(.class == "started" and .attempt == $attempt)' \
    "${ARTIFACT_DIR}/account-roles-${operation}-auth.jsonl" >/dev/null || return 94
  if [[ "${credential}" == sso ]]; then
    [[ "$*" == "login --env ${OCM_LOGIN_ENV} --client-id fixture-client --client-secret fixture-secret" ]] || return 95
  else
    [[ "$*" == "login --env ${OCM_LOGIN_ENV} --token fixture-token" ]] || return 96
  fi
  printf '%s\n' 'fixture-client fixture-secret fixture-token RAW_LOGIN_OUTPUT Authorization: synthetic response body'
  printf '%s\n' 'RAW_LOGIN_ERROR' >&2
  case "${scenario}" in
    html-third) failure=html ;;
    transport-exhaustion) failure=transport ;;
    later-unknown|later-rejection)
      if [[ "${attempt}" -eq 1 ]]; then failure=html; else failure="${scenario#later-}"; fi ;;
  esac
  case "${failure}" in
    success|other-env) return 0 ;;
    html|exhaustion) printf "%s\n" "expected response content type 'application/json' but received 'text/html'" >&2 ;;
    transport) printf '%s\n' "${transport}" >&2 ;;
    rejection) printf '%s\n' "${rejection}; expected response content type 'application/json' but received 'text/html'; i/o timeout" >&2 ;;
    unknown) printf '%s\n' 'unrecognized failure' >&2 ;;
    *) return 97 ;;
  esac
  case "${scenario}:${attempt}" in
    html:2|transport:2|html-third:3) return 0 ;;
  esac
  return "$((40 + attempt))"
}
aws() { printf 'aws\n' >> "${case_dir}/operations"; }
sleep() { printf '%s\n' "$*" >> "${case_dir}/sleeps"; }
export -f rosa aws sleep

run_case() {
  local scenario="$1" credential="$2" transport="${3:-}" rejection="${4:-}"
  local expected=0 attempts=1 result=0 expected_class=success environment="${5:-staging}" retry_class=retryable_html
  case_dir="${test_dir}/${operation}-${count}"
  mkdir -p "${case_dir}"/{profile,shared,artifacts}
  export case_dir scenario credential transport rejection operation
  export ARTIFACT_DIR="${case_dir}/artifacts" CLUSTER_PROFILE_DIR="${case_dir}/profile" SHARED_DIR="${case_dir}/shared"
  export LEASED_RESOURCE=fixture-region CHANNEL_GROUP=stable OPENSHIFT_VERSION=4.21 ARN_PATH=''
  export OCM_LOGIN_ENV="${environment}"
  printf fixture > "${CLUSTER_PROFILE_DIR}/.awscred"
  printf fixture > "${SHARED_DIR}/cluster-prefix"
  case "${credential}" in
    sso)
      printf fixture-client > "${CLUSTER_PROFILE_DIR}/sso-client-id"
      printf fixture-secret > "${CLUSTER_PROFILE_DIR}/sso-client-secret"
      printf fixture-token > "${CLUSTER_PROFILE_DIR}/ocm-token" ;;
    token) printf fixture-token > "${CLUSTER_PROFILE_DIR}/ocm-token" ;;
    partial)
      printf fixture-client > "${CLUSTER_PROFILE_DIR}/sso-client-id"
      printf fixture-token > "${CLUSTER_PROFILE_DIR}/ocm-token" ;;
    missing) expected=1; attempts=0; expected_class=missing_credentials ;;
    missing-secret)
      printf fixture-client > "${CLUSTER_PROFILE_DIR}/sso-client-id"
      expected=1; attempts=0; expected_class=missing_credentials ;;
    missing-id)
      printf fixture-secret > "${CLUSTER_PROFILE_DIR}/sso-client-secret"
      expected=1; attempts=0; expected_class=missing_credentials ;;
  esac
  case "${scenario}" in
    html|transport) attempts=2 ;;
    html-third) attempts=3 ;;
    exhaustion) expected=43; attempts=3; expected_class=retryable_html ;;
    transport-exhaustion) expected=43; attempts=3; expected_class=retryable_transport ;;
    rejection) expected=41; expected_class=auth_rejected ;;
    later-rejection) expected=42; attempts=2; expected_class=auth_rejected ;;
    unknown) expected=41; expected_class=unclassified ;;
    later-unknown) expected=42; attempts=2; expected_class=unclassified ;;
    other-env) export OCM_LOGIN_ENV='https://fixture.invalid/private?value=ENVIRONMENT_CANARY'; environment=other ;;
  esac
  [[ "${scenario}" != transport* ]] || retry_class=retryable_transport
  local source="${root}/ci-operator/step-registry/rosa/sts/account-roles/${operation}/rosa-sts-account-roles-${operation}-commands.sh"
  bash -x -c "$(cat "${source}")" > "${case_dir}/stdout" 2> "${case_dir}/stderr" || result=$?
  [[ "${result}" -eq "${expected}" ]] || { printf 'Unexpected exit: %s/%s/%s: %s != %s\n' "${operation}" "${scenario}" "${credential}" "${result}" "${expected}"; return 1; }
  local actual_attempts=0
  [[ ! -f "${case_dir}/calls" ]] || read -r actual_attempts < "${case_dir}/calls"
  [[ "${actual_attempts}" -eq "${attempts}" ]]
  local report="${ARTIFACT_DIR}/account-roles-${operation}-auth.jsonl"
  jq -se --arg operation "account-roles-${operation}" --arg environment "${environment}" \
    --arg class "${expected_class}" --arg retry_class "${retry_class}" \
    --argjson exit_code "${expected}" --argjson attempts "${attempts}" '
    length == (if $attempts == 0 then 1 else $attempts * 2 end) and
    all(.[]; .operation == $operation and .environment == $environment and .max_attempts == 3 and
      .endpoint == "unknown" and .http_status == "unknown" and
      (.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))) and
    .[-1].class == $class and .[-1].exit_code == $exit_code and .[-1].attempt == $attempts and
    (if $attempts == 0 then true else
      [ .[] | select(.class == "started") | .attempt ] == [range(1; $attempts + 1)] and
      all(.[] | select(.class == "started"); .exit_code == null) and
      ([.[] | select(.class != "started")] as $results |
        all(range(0; $attempts - 1); $results[.].class == $retry_class and
          $results[.].exit_code == (41 + .) and $results[.].attempt == (. + 1))) end)
  ' "${report}" >/dev/null
  while IFS= read -r event; do
    grep -Fx -- "${event}" "${case_dir}/stderr" >/dev/null
  done < "${report}"
  if grep -ER 'fixture-client|fixture-secret|fixture-token|RAW_LOGIN|Authorization:|synthetic response body|ENVIRONMENT_CANARY' \
    "${ARTIFACT_DIR}" "${case_dir}/stdout" "${case_dir}/stderr" > /dev/null; then
    printf 'Unsafe output in case %s\n' "${count}"
    return 1
  fi
  if [[ "${expected}" -ne 0 ]]; then
    [[ ! -f "${case_dir}/operations" ]]
  else
    grep -F "${operation} account-roles" "${case_dir}/operations" >/dev/null
    if [[ "${operation}" == create ]]; then
      grep -Fx aws "${case_dir}/operations" >/dev/null
      [[ -s "${SHARED_DIR}/account-roles-arns" && -s "${SHARED_DIR}/openshift_version" ]]
    fi
  fi
  if [[ "${attempts}" -lt 2 ]]; then
    [[ ! -f "${case_dir}/sleeps" ]]
  elif [[ "${attempts}" -eq 2 ]]; then
    [[ "$(cat "${case_dir}/sleeps")" == 10 ]]
  else
    [[ "$(cat "${case_dir}/sleeps")" == $'10\n20' ]]
  fi
  printf 'PASS %s %s %s\n' "${operation}" "${scenario}" "${credential}"
  count=$((count + 1))
}

count=0
for operation in create delete; do
  for credential in sso token partial; do
    for scenario in success html html-third exhaustion unknown later-unknown other-env; do
      run_case "${scenario}" "${credential}"
    done
    run_case later-rejection "${credential}" '' invalid_client
    for environment in production prod stage integration; do
      run_case success "${credential}" '' '' "${environment}"
    done
    for transport in 'i/o timeout' 'TLS handshake timeout' 'connection reset by peer' 'unexpected EOF' \
      'temporary failure in name resolution' 'context deadline exceeded'; do
      run_case transport "${credential}" "${transport}"
      run_case transport-exhaustion "${credential}" "${transport}"
    done
    for rejection in invalid_grant invalid_client unauthorized_client access_denied unauthorized forbidden \
      'invalid token' 'invalid refresh token' 'invalid credentials' 'authentication failed'; do
      run_case rejection "${credential}" '' "${rejection}"
    done
  done
  run_case missing missing
  run_case missing missing-secret
  run_case missing missing-id
done
printf 'PASS: %s offline inline-execution cases\n' "${count}"
