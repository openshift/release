#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts=(
  "ci-operator/step-registry/azure/provision/role-assignment/hypershift/azure-provision-role-assignment-hypershift-commands.sh"
  "ci-operator/step-registry/hypershift/azure/aks/attach-kv/hypershift-azure-aks-attach-kv-commands.sh"
  "ci-operator/step-registry/aks/provision/aks-provision-commands.sh"
  "ci-operator/step-registry/aks/deprovision/aks-deprovision-commands.sh"
)
mutation_scripts=(
  "${scripts[0]}"
  "${scripts[1]}"
  "${scripts[3]}"
)
role_assignment_scripts=(
  "${scripts[0]}"
  "${scripts[1]}"
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

extract_helper() {
  local script="$1"
  sed -n '/^# BEGIN AZURE CLI RETRY HELPER$/,/^# END AZURE CLI RETRY HELPER$/p' "${repo_root}/${script}" | sed '1d;$d'
}

extract_mutation_helper() {
  local script="$1"
  sed -n '/^# BEGIN AZURE CLI MUTATION RETRY HELPER$/,/^# END AZURE CLI MUTATION RETRY HELPER$/p' "${repo_root}/${script}" | sed '1d;$d'
}

extract_role_assignment_helper() {
  local script="$1"
  sed -n '/^# BEGIN AZURE ROLE ASSIGNMENT RECONCILIATION$/,/^# END AZURE ROLE ASSIGNMENT RECONCILIATION$/p' "${repo_root}/${script}" | sed '1d;$d'
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

extract_helper "${scripts[0]}" >"${tmpdir}/retry-helper.sh"
[[ -s "${tmpdir}/retry-helper.sh" ]] || fail "retry helper was not found"

for script in "${scripts[@]:1}"; do
  extract_helper "${script}" >"${tmpdir}/candidate-helper.sh"
  cmp -s "${tmpdir}/retry-helper.sh" "${tmpdir}/candidate-helper.sh" || fail "retry helper differs in ${script}"
done

extract_mutation_helper "${mutation_scripts[0]}" >"${tmpdir}/mutation-retry-helper.sh"
[[ -s "${tmpdir}/mutation-retry-helper.sh" ]] || fail "mutation retry helper was not found"
for script in "${mutation_scripts[@]:1}"; do
  extract_mutation_helper "${script}" >"${tmpdir}/candidate-mutation-helper.sh"
  cmp -s "${tmpdir}/mutation-retry-helper.sh" "${tmpdir}/candidate-mutation-helper.sh" || fail "mutation retry helper differs in ${script}"
done

extract_role_assignment_helper "${role_assignment_scripts[0]}" >"${tmpdir}/role-assignment-helper.sh"
[[ -s "${tmpdir}/role-assignment-helper.sh" ]] || fail "role assignment helper was not found"
extract_role_assignment_helper "${role_assignment_scripts[1]}" >"${tmpdir}/candidate-role-assignment-helper.sh"
cmp -s "${tmpdir}/role-assignment-helper.sh" "${tmpdir}/candidate-role-assignment-helper.sh" || fail "role assignment helpers differ"

# The helper is intentionally copied into each command script because ci-operator
# executes each registry command as a standalone script in its step container.
# shellcheck source=/dev/null
source "${tmpdir}/retry-helper.sh"
# shellcheck source=/dev/null
source "${tmpdir}/mutation-retry-helper.sh"
# shellcheck source=/dev/null
source "${tmpdir}/role-assignment-helper.sh"

call_count_file="${tmpdir}/call-count"
sleep_log="${tmpdir}/sleep-log"
printf '0\n' >"${call_count_file}"
: >"${sleep_log}"

sleep_rc=0
sleep() {
  printf '%s\n' "$1" >>"${sleep_log}"
  return "${sleep_rc}"
}

increment_call_count() {
  local count
  count="$(<"${call_count_file}")"
  count=$((count + 1))
  printf '%s\n' "${count}" >"${call_count_file}"
  printf '%s' "${count}"
}

transient_then_success() {
  local count
  count="$(increment_call_count)"
  if ((count < 3)); then
    echo "partial-output-${count}"
    echo "urllib3.exceptions.NameResolutionError: Failed to resolve 'graph.microsoft.com'" >&2
    return 17
  fi
  echo "expected-output"
  echo "success warning" >&2
}

run_az_with_retry "test lookup" transient_then_success >"${tmpdir}/stdout" 2>"${tmpdir}/stderr" || fail "transient failure did not recover"
[[ "$(<"${call_count_file}")" == "3" ]] || fail "transient failure used the wrong attempt count"
[[ "$(<"${tmpdir}/stdout")" == "expected-output" ]] || fail "failed-attempt stdout leaked into the successful result"
[[ "$(tr '\n' ' ' <"${sleep_log}")" == "5 10 " ]] || fail "backoff did not use 5s then 10s"
grep -q 'success warning' "${tmpdir}/stderr" || fail "successful command stderr was not preserved"

printf '0\n' >"${call_count_file}"
: >"${sleep_log}"
non_transient_failure() {
  increment_call_count >/dev/null
  echo "ERROR: AuthorizationFailed" >&2
  return 23
}

set +e
run_az_with_retry "test lookup" non_transient_failure "sensitive-argument" >"${tmpdir}/stdout" 2>"${tmpdir}/stderr"
rc=$?
set -e
[[ "${rc}" == "23" ]] || fail "non-transient exit code was not preserved"
[[ "$(<"${call_count_file}")" == "1" ]] || fail "non-transient failure was retried"
[[ ! -s "${sleep_log}" ]] || fail "non-transient failure slept before returning"
! grep -q 'sensitive-argument' "${tmpdir}/stderr" || fail "helper diagnostic leaked command arguments"

printf '0\n' >"${call_count_file}"
: >"${sleep_log}"
signal_terminated_command() {
  increment_call_count >/dev/null
  echo "requests.exceptions.ConnectionError: network is unreachable" >&2
  return 130
}

set +e
run_az_with_retry "test lookup" signal_terminated_command >"${tmpdir}/stdout" 2>"${tmpdir}/stderr"
rc=$?
set -e
[[ "${rc}" == "130" ]] || fail "signal-style command status was not preserved"
[[ "$(<"${call_count_file}")" == "1" ]] || fail "signal-terminated command was retried"
[[ ! -s "${sleep_log}" ]] || fail "signal-terminated command slept before returning"

printf '0\n' >"${call_count_file}"
: >"${sleep_log}"
permanent_tls_failure() {
  increment_call_count >/dev/null
  echo "azure.core.exceptions.ServiceRequestError: certificate verify failed" >&2
  return 60
}

set +e
run_az_with_retry "test lookup" permanent_tls_failure >"${tmpdir}/stdout" 2>"${tmpdir}/stderr"
rc=$?
set -e
[[ "${rc}" == "60" ]] || fail "permanent TLS exit code was not preserved"
[[ "$(<"${call_count_file}")" == "1" ]] || fail "permanent TLS failure was retried"
[[ ! -s "${sleep_log}" ]] || fail "permanent TLS failure slept before returning"

printf '0\n' >"${call_count_file}"
: >"${sleep_log}"
always_transient() {
  increment_call_count >/dev/null
  echo "requests.exceptions.ConnectionError: network is unreachable" >&2
  return 42
}

set +e
run_az_with_retry "test lookup" always_transient >"${tmpdir}/stdout" 2>"${tmpdir}/stderr"
rc=$?
set -e
[[ "${rc}" == "42" ]] || fail "exhausted retry exit code was not preserved"
[[ "$(<"${call_count_file}")" == "4" ]] || fail "retry attempts were not bounded at four"
[[ "$(tr '\n' ' ' <"${sleep_log}")" == "5 10 20 " ]] || fail "bounded exponential backoff was not 5s, 10s, 20s"
grep -q 'failed after 4 attempts' "${tmpdir}/stderr" || fail "retry exhaustion diagnostic was missing"

printf '0\n' >"${call_count_file}"
: >"${sleep_log}"
sleep_rc=130
set +e
run_az_with_retry "test lookup" always_transient >"${tmpdir}/stdout" 2>"${tmpdir}/stderr"
rc=$?
set -e
[[ "${rc}" == "130" ]] || fail "interrupted backoff status was not propagated"
[[ "$(<"${call_count_file}")" == "1" ]] || fail "command was retried after interrupted backoff"

mutation_state="absent"
mutation_mode="lost-response"
sleep_rc=0
printf '0\n' >"${call_count_file}"
: >"${sleep_log}"
desired_state_reached() {
  if [[ "${mutation_state}" == "present" ]]; then
    # shellcheck disable=SC2034 # consumed by the sourced mutation helper
    AZURE_CLI_DESIRED_STATE=true
  fi
  return 0
}
test_mutation() {
  local count
  count="$(increment_call_count)"
  case "${mutation_mode}" in
    lost-response)
      mutation_state="present"
      echo "requests.exceptions.ConnectionError: RemoteDisconnected" >&2
      return 17
      ;;
    fail-before-success)
      if ((count == 1)); then
        echo "NameResolutionError: Failed to resolve management.azure.com" >&2
        return 17
      fi
      mutation_state="present"
      ;;
    permanent)
      echo "ERROR: AuthorizationFailed" >&2
      return 23
      ;;
  esac
}

run_az_mutation_with_reconcile "test creation" desired_state_reached -- test_mutation >"${tmpdir}/stdout" 2>"${tmpdir}/stderr" || fail "lost mutation response was not reconciled"
[[ "$(<"${call_count_file}")" == "1" ]] || fail "mutation repeated after desired state was observed"
[[ ! -s "${sleep_log}" ]] || fail "reconciled mutation slept before returning"

mutation_state="absent"
mutation_mode="fail-before-success"
printf '0\n' >"${call_count_file}"
: >"${sleep_log}"
run_az_mutation_with_reconcile "test creation" desired_state_reached -- test_mutation >"${tmpdir}/stdout" 2>"${tmpdir}/stderr" || fail "pre-request mutation failure did not recover"
[[ "$(<"${call_count_file}")" == "2" ]] || fail "pre-request failure used the wrong mutation count"
[[ "$(tr '\n' ' ' <"${sleep_log}")" == "5 " ]] || fail "mutation retry did not use the first 5s backoff"

mutation_state="absent"
mutation_mode="permanent"
printf '0\n' >"${call_count_file}"
: >"${sleep_log}"
set +e
run_az_mutation_with_reconcile "test creation" desired_state_reached -- test_mutation >"${tmpdir}/stdout" 2>"${tmpdir}/stderr"
rc=$?
set -e
[[ "${rc}" == "23" ]] || fail "non-transient mutation exit code was not preserved"
[[ "$(<"${call_count_file}")" == "1" ]] || fail "non-transient mutation was retried"
[[ ! -s "${sleep_log}" ]] || fail "non-transient mutation slept before returning"

# A successful create can have a lost response followed by a stale empty list.
# The retry must use the same deterministic Azure role-assignment resource name.
backend_state_file="${tmpdir}/backend-state"
stale_reads_file="${tmpdir}/stale-reads"
assignment_names_file="${tmpdir}/assignment-names"
durable_effects_file="${tmpdir}/durable-effects"
printf 'absent\n' >"${backend_state_file}"
printf '1\n' >"${stale_reads_file}"
: >"${assignment_names_file}"
printf '0\n' >"${durable_effects_file}"
printf '0\n' >"${call_count_file}"
: >"${sleep_log}"
az() {
  if [[ "${1:-} ${2:-} ${3:-}" == "role assignment list" ]]; then
    if [[ "$(<"${backend_state_file}")" == "present" ]]; then
      local stale_reads
      stale_reads="$(<"${stale_reads_file}")"
      if ((stale_reads > 0)); then
        printf '%s\n' "$((stale_reads - 1))" >"${stale_reads_file}"
      else
        echo "assignment-id"
      fi
    fi
    return 0
  fi
  if [[ "${1:-} ${2:-} ${3:-}" == "role assignment create" ]]; then
    increment_call_count >/dev/null
    local assignment_name=""
    while (($#)); do
      if [[ "$1" == "--name" ]]; then
        assignment_name="$2"
        break
      fi
      shift
    done
    [[ -n "${assignment_name}" ]] || return 2
    printf '%s\n' "${assignment_name}" >>"${assignment_names_file}"
    if [[ "$(<"${backend_state_file}")" != "present" ]]; then
      printf 'present\n' >"${backend_state_file}"
      local durable_effects
      durable_effects="$(<"${durable_effects_file}")"
      printf '%s\n' "$((durable_effects + 1))" >"${durable_effects_file}"
      echo "requests.exceptions.ConnectionError: RemoteDisconnected" >&2
      return 17
    fi
    return 0
  fi
  return 2
}

ensure_role_assignment "principal-id" "role-id" "/subscriptions/sub/resourceGroups/rg" >"${tmpdir}/stdout" 2>"${tmpdir}/stderr" || fail "stale role-assignment read did not recover"
[[ "$(<"${call_count_file}")" == "2" ]] || fail "stale role-assignment scenario did not exercise a repeated request"
[[ "$(<"${durable_effects_file}")" == "1" ]] || fail "repeated request created a second durable assignment"
[[ "$(sort -u "${assignment_names_file}" | wc -l)" == "1" ]] || fail "role-assignment retry used different resource names"
grep -Eq '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' "${assignment_names_file}" || fail "role-assignment name is not a deterministic GUID"

echo "Azure CLI retry helper tests: PASS"
