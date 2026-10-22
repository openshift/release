#!/bin/bash

set +x
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

ocm_login_with_retry() {
  local attempt output status failure_class delay started
  for attempt in 1 2 3; do
    started=${SECONDS}
    if output=$(ocm login "$@" 2>&1); then
      echo "OCM login attempt ${attempt}/3 succeeded after $((SECONDS - started))s"
      return 0
    else
      status=$?
    fi

    case "${output,,}" in
      *invalid_client*|*invalid_grant*|*invalid*credentials*|*unauthorized*|*forbidden*)
        failure_class=authentication ;;
      *"connection reset by peer"*|*"net/http: tls handshake timeout"*)
        failure_class=transport ;;
      *)
        failure_class=unrecognized ;;
    esac
    echo "OCM login attempt ${attempt}/3 failed after $((SECONDS - started))s (${failure_class})" >&2
    if [[ "${failure_class}" != transport || "${attempt}" == 3 ]]; then
      return "${status}"
    fi
    delay=$((attempt * 2))
    echo "Retrying OCM login in ${delay}s" >&2
    sleep "${delay}"
  done
}

# Log in
OCM_VERSION=$(ocm version)
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm_login_with_retry --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
  ocm_login_with_retry --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

# Get the HTPasswd IDP ID
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
IDP_ID=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/identity_providers" --parameter search="type is 'HTPasswdIdentityProvider'" | jq -r '.items[].id' | head -n 1)
IDP_INFO=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/identity_providers/${IDP_ID}")
# Generate mulitple users 
echo "Generate the mulitple users under ${IDP_INFO} the htpasswd idp ..."
users=""
for i in $(seq 1 ${USER_COUNT});
do
  username="testuser-${i}"
  password="HTPasswd_$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)"
  users+="${username}:${password},"
  payload=$(echo -e '{
    "username": "'${username}'",
    "password": "'${password}'"
  }')

  echo "Adding user ${username}"
  echo "${payload}" | jq -c | ocm post "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/identity_providers/${IDP_ID}/htpasswd_users"
done

# Store users in a shared file
echo "export USERS=${users}" > "${SHARED_DIR}/runtime_env"
