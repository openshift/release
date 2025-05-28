#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}


source ./tests/prow_ci.sh

# functions are defined in https://github.com/openshift/rosa/blob/master/tests/prow_ci.sh
#configure aws
aws_region=${REGION:-$LEASED_RESOURCE}
configure_aws "${CLUSTER_PROFILE_DIR}/.awscred" "${aws_region}"
configure_aws_shared_vpc ${CLUSTER_PROFILE_DIR}/.awscred_shared_account

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}
# Log in
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials using rosa cli"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  log "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

NAME_PREFIX=${NAME_PREFIX:-}

cluster_id=$(ocm list clusters --columns=id --parameter search="name like '${NAME_PREFIX}-%' and status.state is 'ready'" --parameter order="creation_timestamp desc" --no-headers | tail -n 1)

if [[ -z "${cluster_id}" ]]; then
  log "Didn't find the cluster with conditions: name like '${NAME_PREFIX}-%' and status.state is 'ready'"
  exit 1
fi

# Store cluster config
ocm get cluster $cluster_id > ${SHARED_DIR}/cluster-config 2>&1 || true

# Store cluster type
ocm get cluster $cluster_id | jq -r ".product.id"  > ${SHARED_DIR}/cluster-type 2>&1 || true

# Store cluster-id
echo "cluster-id file: ${SHARED_DIR}/cluster-id"
echo $cluster_id >> "${SHARED_DIR}/cluster-id"