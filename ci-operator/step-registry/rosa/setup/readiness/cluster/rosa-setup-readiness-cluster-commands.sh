#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM


HOSTED_CP=${HOSTED_CP:-false}
BYO_OIDC=${BYO_OIDC:-false}
ENABLE_BYOVPC=${ENABLE_BYOVPC:-false}
ENABLE_SHARED_VPC=${ENABLE_SHARED_VPC:-"no"}
CLUSTER_TIMEOUT=${CLUSTER_TIMEOUT}
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

# Record Cluster Configurations
cluster_config_file="${SHARED_DIR}/cluster-config"
function record_cluster() {
  if [ $# -eq 2 ]; then
    location="."
    key=$1
    value=$2
  else
    location=".$1"
    key=$2
    value=$3
  fi

  payload=$(cat $cluster_config_file)
  if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
    echo $payload | jq "$location += {\"$key\":$value}" > $cluster_config_file
  else
    echo $payload | jq "$location += {\"$key\":\"$value\"}" > $cluster_config_file
  fi
}

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
if [[ "$HOSTED_CP" == "true" ]] && [[ ! -z "$REGION" ]]; then
  CLOUD_PROVIDER_REGION="${REGION}"
fi

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

export SHARED_VPC_AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"

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
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi
AWS_ACCOUNT_ID=$(rosa whoami --output json | jq -r '."AWS Account ID"')
AWS_ACCOUNT_ID_MASK=$(echo "${AWS_ACCOUNT_ID:0:4}***")

# Wait for cluster to be ready
log "Waiting for cluster ready..."

export TEST_PROFILE=${TEST_PROFILE}
# Variables
if [[ -z "$TEST_PROFILE" ]]; then
  log "ERROR: " "TEST_PROFILE is mandatory."
  exit 1
fi

cluster_info_json=$(mktemp)

record_cluster "timers" "status" "claim"

rosatest --ginkgo.v --ginkgo.no-color \
  --ginkgo.timeout "60m" \
  --ginkgo.label-filter "day1-readiness" | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g"

# Verify the subnets of the cluster to remove the 'Inflight Checks' warning
if [[ "$ENABLE_BYOVPC" == "true" ]]; then
  verify_cmd=$(rosa verify network -c ${CLUSTER_ID} | grep 'rosa verify network' || true)
  if [[ ! -z "$verify_cmd" ]]; then
    echo -e "Force verifying the network of the cluster to remove the 'Inflight Checks' warning\n$verify_cmd"
    eval $verify_cmd
  fi
fi

# Output
cluster_info_json=$(mktemp)
rosa describe cluster -c "${CLUSTER_ID}" -o json > ${cluster_info_json}
API_URL=$(cat $cluster_info_json | jq -r '.api.url')
CONSOLE_URL=$(cat $cluster_info_json | jq -r '.console.url')
if [[ "${API_URL}" == "null" ]]; then
  port="6443"
  if [[ "$HOSTED_CP" == "true" ]]; then
    port="443"
  fi
  log "warning: API URL was null, attempting to build API URL"
  base_domain=$(cat $cluster_info_json | jq -r '.dns.base_domain')
  CLUSTER_NAME=$(cat $cluster_info_json | jq -r '.name')
  echo "info: Using baseDomain : ${base_domain} and clusterName : ${CLUSTER_NAME}"
  API_URL="https://api.${CLUSTER_NAME}.${base_domain}:${port}"
  CONSOLE_URL="https://console-openshift-console.apps.${CLUSTER_NAME}.${base_domain}"
fi
echo "API URL: ${API_URL}"
echo "Console URL: ${CONSOLE_URL}"
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"
echo "${API_URL}" > "${SHARED_DIR}/api.url"

PRODUCT_ID=$(cat $cluster_info_json | jq -r '.product.id')
echo "${PRODUCT_ID}" > "${SHARED_DIR}/cluster-type"

INFRA_ID=$(cat $cluster_info_json | jq -r '.infra_id')
if [[ "$HOSTED_CP" == "true" ]] && [[ "${INFRA_ID}" == "null" ]]; then
  # Currently, there is no infra_id for rosa hypershift cluster, use a fake one instead of null
  INFRA_ID=$(cat $cluster_info_json | jq -r '.name')
fi
echo "${INFRA_ID}" > "${SHARED_DIR}/infra_id"
