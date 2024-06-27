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

# Get shared_vpc mask
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  if [[ ! -e "${CLUSTER_PROFILE_DIR}/.awscred_shared_account" ]]; then
    echo "Error: Shared VPC is enabled, but not find .awscred_shared_account, exit now"
    exit 1
  fi
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"

  SHARED_VPC_AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text | awk '{print $1}')
  SHARED_VPC_AWS_ACCOUNT_ID_MASK=$(echo "${SHARED_VPC_AWS_ACCOUNT_ID:0:4}***")

  # reset
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
fi

function post_shared_vpc_auto(){
  local -r cluster_info_json=$1; shift
  echo "Shared-VPC: Auto mode is enabled, adding ingress operator arn to shrared-role's trust policy"
  status_description=$(cat $cluster_info_json | jq -r '.status.description')
  match=$(echo ${status_description} | grep -E "^Failed to verify ingress operator for shared VPC:.*OCM is not authorized to perform: sts:AssumeRole on resource:.*" || true)
  echo "Shared-VPC: cluster status: ${status_description}" \
    | sed "s/${AWS_ACCOUNT_ID}/${AWS_ACCOUNT_ID_MASK}/g" | sed "s/${SHARED_VPC_AWS_ACCOUNT_ID}/${SHARED_VPC_AWS_ACCOUNT_ID_MASK}/g"

  if [[ ${match} != "" ]]; then
    echo "Shared-VPC: Status match, waiting for 2 mins to make sure operator role is ready."
    sleep 120

    account_intaller_role_arn=$(cat "${cluster_info_json}" | jq -r '.aws.sts.role_arn')
    ingress_operator_arn=$(cat "${cluster_info_json}" | jq -r '.aws.sts.operator_iam_roles[] | select(.namespace=="openshift-ingress-operator") .role_arn')
    shared_role_name=$(cat "${cluster_info_json}" | jq -r '.aws.private_hosted_zone_role_arn' | cut -d '/' -f 2)
    echo "Shared-VPC: ingress: ${ingress_operator_arn}, shared_role: ${shared_role_name}, installer: ${account_intaller_role_arn}" \
      | sed "s/${AWS_ACCOUNT_ID}/${AWS_ACCOUNT_ID_MASK}/g" \
      | sed "s/${SHARED_VPC_AWS_ACCOUNT_ID}/${SHARED_VPC_AWS_ACCOUNT_ID_MASK}/g"

    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
    trust_policy=$(mktemp)
    cat > ${trust_policy} <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Principal": {
              "AWS": [
                "${account_intaller_role_arn}",
                "${ingress_operator_arn}"
              ]
          },
          "Action": "sts:AssumeRole",
          "Condition": {}
      }
  ]
}
EOF
    aws iam update-assume-role-policy --role-name ${shared_role_name} --policy-document file://${trust_policy}
    echo "Shared-VPC: Applied new policy."

    echo "Shared-VPC: waiting for 2 mins to make sure the cluster status is up to date."
    sleep 120

    # reset
    export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  else
    echo "Shared-VPC: Status not match, continuing"
  fi
}

# Wait for cluster to be ready
log "Waiting for cluster ready..."
FAILED_INSTALL="no"
cluster_info_json=$(mktemp)
start_time=$(date +"%s")
dyn_start_time=${start_time}
CLUSTER_PREVIOUS_STATE="claim"
record_cluster "timers" "status" "claim"
while true; do
  rosa describe cluster -c "${CLUSTER_ID}" -o json > ${cluster_info_json}
  CLUSTER_STATE=$(cat ${cluster_info_json} | jq -r '.state')
  log "Cluster state: ${CLUSTER_STATE}"
  current_time=$(date +"%s")
  if [[ "${CLUSTER_STATE}" == "error" ]] || (( "${current_time}" - "${start_time}" >= "${CLUSTER_TIMEOUT}" )); then
    record_cluster "timers" "status" "${CLUSTER_STATE}"
    FAILED_INSTALL="yes"
    break
  fi
  if [[ "${CLUSTER_STATE}" != "${CLUSTER_PREVIOUS_STATE}" ]] ; then
    record_cluster "timers" "status" "${CLUSTER_STATE}"
    record_cluster "timers.install" "${CLUSTER_PREVIOUS_STATE}" $(( "${current_time}" - "${dyn_start_time}" ))
    dyn_start_time=${current_time}
    CLUSTER_PREVIOUS_STATE=${CLUSTER_STATE}
    if [[ "${CLUSTER_STATE}" == "ready" ]]; then
      break
    fi
  else
      if [[ ${CLUSTER_STATE} == "installing" ]]; then
      	sleep 60
      else
        sleep 1
      fi
  fi
  if [[ "${CLUSTER_STATE}" == "waiting" ]] && [[ "${ENABLE_SHARED_VPC}" == "yes" ]] && [[ "${BYO_OIDC}" == "false" ]]; then
    # Adding ingress role to trust policy
    post_shared_vpc_auto ${cluster_info_json}
  fi
done
cat $cluster_config_file | jq -r '.timers'

if [[ "$FAILED_INSTALL" == "yes" ]]; then
  rosa logs install -c ${CLUSTER_ID} > "${ARTIFACT_DIR}/.install.log"
  exit 1
fi

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
if [[ "$HOSTED_CP" == "true" ]]; then
  # Record Hosted clusters Provision shard id to trace the SC and MC details ir required
  PROV_SHARD_ID=$(cat $cluster_info_json | jq -r '.properties.provision_shard_id')
  echo "ROSA HCP Prov Shard ID: ${PROV_SHARD_ID}"
  echo "${PROV_SHARD_ID}" > "${SHARED_DIR}/prov_shard_id"
  if [[ "${INFRA_ID}" == "null" ]]; then
    # Currently, there is no infra_id for rosa hypershift cluster, use a fake one instead of null
    INFRA_ID=$(cat $cluster_info_json | jq -r '.name')
  fi
fi
echo "${INFRA_ID}" > "${SHARED_DIR}/infra_id"
