#!/bin/bash

set +x
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

AUTH_OPERATION=account-roles-delete
AUTH_REPORT="${ARTIFACT_DIR}/${AUTH_OPERATION}-auth.jsonl"
: > "${AUTH_REPORT}"

retry_with_backoff() {
  local max_retries="${1}"
  shift
  local cmd=("$@")
  local attempt=1
  local rc=0
  local backoff=30

  while [[ ${attempt} -le ${max_retries} ]]; do
    echo "Attempt ${attempt}/${max_retries}: ${cmd[*]}"
    rc=0
    "${cmd[@]}" && return 0 || rc=$?
    if [[ ${attempt} -lt ${max_retries} ]]; then
      echo "Attempt ${attempt} failed (exit code ${rc}), retrying in ${backoff}s..."
      sleep ${backoff}
      backoff=$((backoff * 2))
    else
      echo "Attempt ${attempt} failed (exit code ${rc}), no more retries."
    fi
    attempt=$((attempt + 1))
  done
  return ${rc}
}

CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}

# Configure aws
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

auth_diagnostic() {
  local environment="${OCM_LOGIN_ENV}" attempt="$1" exit_code="$2" failure_class="$3"
  case "${environment}" in
    production|prod|staging|stage|integration) ;;
    *) environment=other ;;
  esac
  printf '{"time":"%s","operation":"%s","environment":"%s","attempt":%d,"max_attempts":3,"exit_code":%s,"class":"%s","http_status":"unknown","endpoint":"unknown"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${AUTH_OPERATION}" "${environment}" "${attempt}" "${exit_code}" "${failure_class}" \
    | tee -a "${AUTH_REPORT}" >&2
}

rosa_login() {
  local attempt output exit_code failure_class
  local -a credentials
  if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    credentials=(--client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}")
  elif [[ -n "${ROSA_TOKEN}" ]]; then
    credentials=(--token "${ROSA_TOKEN}")
  else
    auth_diagnostic 0 1 missing_credentials
    return 1
  fi

  for attempt in 1 2 3; do
    auth_diagnostic "${attempt}" null started
    if output=$(rosa login --env "${OCM_LOGIN_ENV}" "${credentials[@]}" 2>&1); then
      auth_diagnostic "${attempt}" 0 success
      return 0
    else
      exit_code=$?
    fi
    output="${output,,}"
    case "${output}" in
      *invalid_grant*|*invalid_client*|*unauthorized_client*|*access_denied*|*unauthorized*|*forbidden*|*invalid\ token*|*invalid\ refresh\ token*|*invalid\ credentials*|*authentication\ failed*)
        failure_class=auth_rejected ;;
      *"expected response content type 'application/json' but received 'text/html'"*)
        failure_class=retryable_html ;;
      *i/o\ timeout*|*tls\ handshake\ timeout*|*connection\ reset\ by\ peer*|*unexpected\ eof*|*temporary\ failure\ in\ name\ resolution*|*context\ deadline\ exceeded*)
        failure_class=retryable_transport ;;
      *) failure_class=unclassified ;;
    esac
    unset output
    auth_diagnostic "${attempt}" "${exit_code}" "${failure_class}"
    if [[ "${failure_class}" != retryable_* || "${attempt}" -eq 3 ]]; then
      return "${exit_code}"
    fi
    sleep "$((attempt * 10))"
  done
}

SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
rosa_login

# If the account roles exist, do deletion.
ACCOUNT_ROLES_PREFIX_FILE="${SHARED_DIR}/cluster-prefix"
if [[ -e "${ACCOUNT_ROLES_PREFIX_FILE}" ]]; then
  ACCOUNT_ROLES_PREFIX=$(cat "${ACCOUNT_ROLES_PREFIX_FILE}")

  echo "Start deleting the account roles with the prefix ${ACCOUNT_ROLES_PREFIX}..."
  set +e
  retry_with_backoff 3 rosa delete account-roles --prefix "${ACCOUNT_ROLES_PREFIX}" -y --mode auto
  ret=$?
  set -e
  if [[ ${ret} -ne 0 ]]; then
    echo "ERROR: Failed to delete account roles after all retries (exit code ${ret})"
    exit ${ret}
  fi
else
  echo "No account roles created in the pre step"
fi
echo "Finish account roles deletion."

