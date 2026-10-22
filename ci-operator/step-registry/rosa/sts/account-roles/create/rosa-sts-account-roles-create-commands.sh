#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

HOSTED_CP=${HOSTED_CP:-false}
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
CHANNEL_GROUP=${CHANNEL_GROUP}
PERMISSIONS_BOUNDARY=${PERMISSIONS_BOUNDARY:-}
ACCOUNT_ROLES_PREFIX=$(head -n 1 "${SHARED_DIR}/cluster-prefix")

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

# Log in
LOGIN_WAS_TRACING=false
case $- in *x*) LOGIN_WAS_TRACING=true ;; esac
# Disable tracing due to credential and login response handling.
set +x
login_environment=unknown
case "${OCM_LOGIN_ENV}" in
  production|staging|integration) login_environment=${OCM_LOGIN_ENV} ;;
esac
login_diagnostics="${ARTIFACT_DIR}/rosa-sts-account-roles-login.jsonl"
mkdir -p "${ARTIFACT_DIR}"
: > "${login_diagnostics}"
login_attempt=0
login_max_attempts=3
login_diagnostic() {
  printf '{"event":"%s","timestamp_utc":"%s","environment":"%s","attempt":%d,"max_attempts":%d,"cli_exit_code":%s,"class":"%s","endpoint":"unknown","http_status":"unknown"}\n' \
    "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${login_environment}" \
    "${login_attempt}" "${login_max_attempts}" "$2" "$3" >> "${login_diagnostics}"
}
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  login_args=(--client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}")
elif [[ -n "${ROSA_TOKEN}" ]]; then
  login_args=(--token "${ROSA_TOKEN}")
else
  login_diagnostic start null started
  login_diagnostic result null missing_credentials
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi
for ((login_attempt=1; login_attempt<=login_max_attempts; login_attempt++)); do
  login_diagnostic start null started
  if login_output=$(rosa login --env "${OCM_LOGIN_ENV}" "${login_args[@]}" 2>&1); then
    login_status=0
    login_class=success
  else
    login_status=$?
    case "${login_output,,}" in
      *invalid_client*|*invalid_grant*|*unauthorized*|*forbidden*|*'invalid token'*|*'token expired'*|*'expired token'*)
        login_class=auth_rejected ;;
      *"expected response content type 'application/json' but received 'text/html'"*)
        login_class=json_html_mismatch ;;
      *'tls handshake timeout'*|*'i/o timeout'*|*'connection reset by peer'*)
        login_class=transport_candidate ;;
      *) login_class=unknown ;;
    esac
  fi
  unset login_output
  login_diagnostic result "${login_status}" "${login_class}"
  printf 'ROSA login attempt %d/%d: %s (CLI exit %d; endpoint/http_status unknown)\n' \
    "${login_attempt}" "${login_max_attempts}" "${login_class}" "${login_status}"
  if [[ "${login_status}" -eq 0 ]]; then
    break
  fi
  if [[ "${login_attempt}" -eq "${login_max_attempts}" ||
        ( "${login_class}" != json_html_mismatch && "${login_class}" != transport_candidate ) ]]; then
    exit "${login_status}"
  fi
  sleep "$((login_attempt * 10))"
done
unset SSO_CLIENT_ID SSO_CLIENT_SECRET ROSA_TOKEN login_args
if [[ "${LOGIN_WAS_TRACING}" == true ]]; then
  set -x
fi
AWS_ACCOUNT_ID=$(rosa whoami --output json | jq -r '."AWS Account ID"')
AWS_ACCOUNT_ID_MASK=$(echo "${AWS_ACCOUNT_ID:0:4}***")

CLUSTER_SWITCH="--classic"
if [[ "$HOSTED_CP" == "true" ]]; then
   CLUSTER_SWITCH="--hosted-cp"
fi

# Resolve the OpenShift version for account roles
VERSION_SWITCH=""

# Get the X.Y from the release payload pullspec if we're using the one from CI
if [[ "$OPENSHIFT_VERSION" == "release:latest" ]]; then
  if [[ -n "${ORIGINAL_RELEASE_IMAGE_LATEST:-}" ]]; then
    OPENSHIFT_VERSION=$(echo "$ORIGINAL_RELEASE_IMAGE_LATEST" | sed -E 's/.*:([0-9]+\.[0-9]+).*/\1/')
  fi
fi

if [[ -z "$OPENSHIFT_VERSION" ]]; then
  if [[ "$HOSTED_CP" == "true" ]]; then
    versionList=$(rosa list versions --channel-group "${CHANNEL_GROUP}" --hosted-cp -o json | jq -r '.[].raw_id')
  else
    versionList=$(rosa list versions --channel-group "${CHANNEL_GROUP}" -o json | jq -r '.[].raw_id')
  fi
  # Resolve version from offset when VERSION_OFFSET_FROM_LATEST is set
  if [[ -n "${VERSION_OFFSET_FROM_LATEST:-}" ]]; then
    readarray -t y_streams < <(echo "$versionList" | cut -d'.' -f1,2 | sort -Vu)
    total=${#y_streams[@]}
    offset=${VERSION_OFFSET_FROM_LATEST}
    source_index=$((total - offset - 1))
    if (( source_index < 0 )); then
      echo "ERROR: Not enough Y-streams for offset ${offset}. Have ${total}: ${y_streams[*]}"
      exit 1
    fi
    OPENSHIFT_VERSION=${y_streams[$source_index]}
    echo "Resolved version from offset ${offset}: ${OPENSHIFT_VERSION} (available Y-streams: ${y_streams[*]})"
  else
    OPENSHIFT_VERSION=$(echo "$versionList" | head -1)
  fi
fi

if [[ -n "$OPENSHIFT_VERSION" ]]; then
  OPENSHIFT_VERSION=$(echo "${OPENSHIFT_VERSION}" | cut -d '.' -f 1,2)
  VERSION_SWITCH="--version ${OPENSHIFT_VERSION} --channel-group ${CHANNEL_GROUP}"
fi

ARN_PATH_SWITCH=""
if [[ ! -z "$ARN_PATH" ]]; then
   ARN_PATH_SWITCH="--path ${ARN_PATH}"
fi

PERMISSIONS_BOUNDARY_SWITCH=""
if [[ ! -z "$PERMISSIONS_BOUNDARY" ]]; then
   PERMISSIONS_BOUNDARY_SWITCH="--permissions-boundary ${PERMISSIONS_BOUNDARY}"
fi

# Create account roles, falling back to latest available version if target lacks published policies
echo "Create the ${CLUSTER_SWITCH} account roles with the prefix '${ACCOUNT_ROLES_PREFIX}'"
echo "rosa create account-roles -y --mode auto --prefix ${ACCOUNT_ROLES_PREFIX} ${CLUSTER_SWITCH} ${VERSION_SWITCH} ${ARN_PATH_SWITCH}"

create_ret=0
rosa create account-roles -y --mode auto \
                          --prefix ${ACCOUNT_ROLES_PREFIX} \
                          ${CLUSTER_SWITCH} \
                          ${VERSION_SWITCH} \
                          ${ARN_PATH_SWITCH} \
                          ${PERMISSIONS_BOUNDARY_SWITCH} \
                          | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g" \
  || create_ret=$?

if [[ "${create_ret}" -ne 0 && "${CHANNEL_GROUP}" == "stable" ]]; then
  echo "ERROR: Account role creation failed (exit ${create_ret}) on stable channel-group"
  exit "${create_ret}"
elif [[ "${create_ret}" -ne 0 ]]; then
  echo "Account role creation failed (exit ${create_ret}). Falling back to latest available version in channel-group ${CHANNEL_GROUP}..."
  if [[ "$HOSTED_CP" == "true" ]]; then
    fallback_version=$(rosa list versions --channel-group "${CHANNEL_GROUP}" ${CLUSTER_SWITCH} -o json 2>/dev/null \
      | jq -r '.[].raw_id' | cut -d'.' -f1,2 | sort -Vu | tail -1 || true)
  else
    fallback_version=$(rosa list versions --channel-group "${CHANNEL_GROUP}" -o json 2>/dev/null \
      | jq -r '.[].raw_id' | cut -d'.' -f1,2 | sort -Vu | tail -1 || true)
  fi
  if [[ -n "${fallback_version}" && "${fallback_version}" != "${OPENSHIFT_VERSION}" ]]; then
    echo "Retrying with version ${fallback_version} (was ${OPENSHIFT_VERSION})"
    OPENSHIFT_VERSION="${fallback_version}"
    VERSION_SWITCH="--version ${OPENSHIFT_VERSION} --channel-group ${CHANNEL_GROUP}"
    rosa create account-roles -y --mode auto \
                              --prefix ${ACCOUNT_ROLES_PREFIX} \
                              ${CLUSTER_SWITCH} \
                              ${VERSION_SWITCH} \
                              ${ARN_PATH_SWITCH} \
                              ${PERMISSIONS_BOUNDARY_SWITCH} \
                              | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g"
  else
    echo "ERROR: No fallback version available in channel-group ${CHANNEL_GROUP}"
    exit 1
  fi
fi

# Share the resolved version (includes fallback if one was used)
if [[ -n "${OPENSHIFT_VERSION:-}" ]]; then
  echo -n "${OPENSHIFT_VERSION}" > "${SHARED_DIR}/openshift_version"
  echo "Stored resolved version ${OPENSHIFT_VERSION} to SHARED_DIR"
fi

# Store the account-role-prefix for the next pre steps and the account roles deletion
echo -n "${ACCOUNT_ROLES_PREFIX}" > "${SHARED_DIR}/account-roles-prefix"
echo "Store the account-role-prefix and the account-roles-arns ..."
ret=0
rosa list account-roles -o json | jq -r '.[].RoleARN' | grep "${ACCOUNT_ROLES_PREFIX}" > "${SHARED_DIR}/account-roles-arns" || ret=$?
if [[ "$ret" != 0 ]]; then
    rosa list account-roles -o json | jq -r '.[].RoleARN' | grep "${ACCOUNT_ROLES_PREFIX}" > "${SHARED_DIR}/account-roles-arns"
fi
echo "Storing successfully"

# Workaround for missing 'ec2:DisassociateAddress' policy for 4.16
account_intaller_role_name=$(cat "${SHARED_DIR}/account-roles-arns" | grep "Installer-Role" | awk -F '/' '{print $NF}')
policy_name=$account_intaller_role_name"-Policy-Inline"

inline_policy=$(mktemp)
cat > $inline_policy <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "ec2:DisassociateAddress"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
aws iam put-role-policy --role-name $account_intaller_role_name --policy-name $policy_name  --policy-document file://${inline_policy}
