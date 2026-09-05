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
STALL_TIMEOUT=${STALL_TIMEOUT:-3600}
PROVISIONER_LAUNCH_TIMEOUT=${PROVISIONER_LAUNCH_TIMEOUT:-900}
if [[ ! "${PROVISIONER_LAUNCH_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  log "ERROR: PROVISIONER_LAUNCH_TIMEOUT must be a non-negative integer, got '${PROVISIONER_LAUNCH_TIMEOUT}'. Using default 900."
  PROVISIONER_LAUNCH_TIMEOUT=900
fi
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

capture_diagnostics_on_crash() {
    log "UNEXPECTED EXIT: Capturing diagnostics before crash..."
    timeout 30 rosa describe cluster -c "${CLUSTER_ID}" -o json > "${ARTIFACT_DIR}/cluster-description.json" 2>&1 || true
    timeout 60 rosa logs install -c "${CLUSTER_ID}" > "${ARTIFACT_DIR}/.install.log" 2>&1 || true
    if [[ "${HOSTED_CP}" != "true" ]]; then
        timeout 30 ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/resources/live" \
            | jq '.resources.cluster_deployment' \
            > "${ARTIFACT_DIR}/cluster-deployment.json" 2>/dev/null || true
    fi
    log "Diagnostics captured to ${ARTIFACT_DIR}/"
}
trap 'capture_diagnostics_on_crash' ERR

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

retry_cmd() {
    local max_retries="${1:-3}"
    local delay="${2:-10}"
    shift 2 || shift $#
    local attempt=1
    local rc=0
    local retry_out
    retry_out=$(mktemp)
    trap 'rm -f "${retry_out}"' RETURN
    while (( attempt <= max_retries )); do
        rc=0
        "$@" > "${retry_out}" && { cat "${retry_out}"; return 0; } || rc=$?
        if (( attempt == max_retries )); then
            log "Command failed after ${max_retries} attempts: $*" >&2
            return ${rc}
        fi
        log "Attempt ${attempt}/${max_retries} failed (exit ${rc}), retrying in ${delay}s..." >&2
        sleep "${delay}"
        delay=$(( delay * 2 ))
        attempt=$(( attempt + 1 ))
    done
    return ${rc}
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
loop_count=0
OCM_RECONCILE_TIMEOUT=${OCM_RECONCILE_TIMEOUT:-900}
install_complete_detected=false
install_complete_time=0
while true; do
  retry_cmd 3 10 rosa describe cluster -c "${CLUSTER_ID}" -o json > "${cluster_info_json}"
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
      # Stall detection: fail early if state is stuck for too long
      stall_elapsed=$(( current_time - dyn_start_time ))

      # OCM state reconciliation detection: check every iteration (not just every 5th)
      # Only when: Classic cluster, state=installing, infra_id is set, past provisioner launch timeout
      if [[ "${HOSTED_CP}" != "true" ]] && [[ "${CLUSTER_STATE}" == "installing" ]] && [[ "${install_complete_detected}" != "true" ]]; then
        infra_id_check=$(jq -r '.infra_id' "${cluster_info_json}")
        installing_elapsed=$(( current_time - dyn_start_time ))
        if [[ "${infra_id_check}" != "null" ]] && (( installing_elapsed >= PROVISIONER_LAUNCH_TIMEOUT )); then
          install_log_check=$(retry_cmd 3 10 timeout 60 rosa logs install -c "${CLUSTER_ID}" 2>&1 || true)
          if echo "${install_log_check}" | grep -Eiq 'install complete!|install completed successfully'; then
            install_complete_detected=true
            install_complete_time=${current_time}
            log "Install completion detected in logs. Starting OCM reconciliation grace period ($(( OCM_RECONCILE_TIMEOUT / 60 )) minutes)."
            log "  OCM has ${OCM_RECONCILE_TIMEOUT} seconds to transition cluster state from 'installing' to 'ready'."
          fi
        fi
      fi

      # OCM reconciliation grace period: if install completed, give OCM time to reconcile
      if [[ "${install_complete_detected}" == "true" ]]; then
        ocm_reconcile_elapsed=$(( current_time - install_complete_time ))
        if (( ocm_reconcile_elapsed >= OCM_RECONCILE_TIMEOUT )); then
          log "FATAL: OCM state reconciliation failure detected."
          log "  OpenShift install completed $(( ocm_reconcile_elapsed / 60 )) minutes ago, but OCM state is still '${CLUSTER_STATE}'."
          log "  OCM reconciliation grace period ($(( OCM_RECONCILE_TIMEOUT / 60 )) minutes) exceeded."
          record_cluster "timers" "status" "ocm_state_stall"
          FAILED_INSTALL="yes"
          break
        else
          log "  OCM reconciliation in progress: $(( ocm_reconcile_elapsed / 60 ))m $(( ocm_reconcile_elapsed % 60 ))s / $(( OCM_RECONCILE_TIMEOUT / 60 ))m"
        fi
      fi

      if [[ "${install_complete_detected}" != "true" ]] && (( stall_elapsed >= STALL_TIMEOUT )) && [[ "${CLUSTER_STATE}" == "installing" || "${CLUSTER_STATE}" == "pending" ]]; then
        log "ERROR: Cluster state '${CLUSTER_STATE}' has not changed for $(( stall_elapsed / 60 )) minutes (stall timeout: $(( STALL_TIMEOUT / 60 )) minutes)"
        log "Cluster appears to be stalled. Failing early."
        record_cluster "timers" "status" "${CLUSTER_STATE}"
        FAILED_INSTALL="yes"
        break
      fi

      # Install log health check: every 5 iterations, check for fatal errors
      loop_count=$((loop_count + 1))
      if (( loop_count % 5 == 0 )); then
        log "Checking install logs for fatal errors..."
        install_log_output=$(retry_cmd 3 10 timeout 60 rosa logs install -c "${CLUSTER_ID}" 2>&1 || true)
        fatal_pattern=$(echo "${install_log_output}" | grep -E "ProvisionFailed|failed to create|InvalidSubnet|LimitExceeded|QuotaExceeded|InsufficientFreeAddresses|UnauthorizedAccess" || true)
        if [[ -n "${fatal_pattern}" ]]; then
          log "ERROR: Fatal error detected in install logs:"
          log "${fatal_pattern}"
          log "Failing early due to unrecoverable error."
          record_cluster "timers" "status" "${CLUSTER_STATE}"
          FAILED_INSTALL="yes"
          break
        fi

        # Provisioner launch detection: for Classic clusters, check if Hive ever started
        if [[ "${HOSTED_CP}" != "true" ]] && [[ "${CLUSTER_STATE}" == "installing" ]]; then
          infra_id_check=$(jq -r '.infra_id' "${cluster_info_json}")
          installing_elapsed=$(( current_time - dyn_start_time ))

          if [[ "${infra_id_check}" == "null" ]] && (( installing_elapsed >= PROVISIONER_LAUNCH_TIMEOUT )); then
            install_log_check=$(retry_cmd 3 10 timeout 60 rosa logs install -c "${CLUSTER_ID}" 2>&1 || true)
            if echo "${install_log_check}" | grep -q "waiting for installation to begin"; then
              log "FATAL: Hive provisioner never launched."
              log "  infra_id is null after $(( installing_elapsed / 60 )) minutes in 'installing' state."
              log "  Install logs still show: 'waiting for installation to begin'"
              log "  This indicates the OCM-to-Hive handoff failed."
              record_cluster "timers" "status" "provisioner_stall"
              FAILED_INSTALL="yes"
              break
            fi
          fi
        fi
      fi

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
  # Save full cluster description for diagnostics
  rosa describe cluster -c "${CLUSTER_ID}" -o json > "${ARTIFACT_DIR}/cluster-description.json" || true
  # Log the cluster status description
  status_desc=$(jq -r '.status.description // "N/A"' "${ARTIFACT_DIR}/cluster-description.json" 2>/dev/null || echo "N/A")
  log "Cluster status description: ${status_desc}"
  # Save install logs
  timeout 60 rosa logs install -c ${CLUSTER_ID} > "${ARTIFACT_DIR}/.install.log" || true
  # Save Hive ClusterDeployment conditions for Classic clusters (not applicable to HyperShift)
  if [[ "${HOSTED_CP}" != "true" ]]; then
    log "Saving Hive ClusterDeployment..."
    ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/resources/live" \
      | jq '.resources.cluster_deployment' \
      > "${ARTIFACT_DIR}/cluster-deployment.json" 2>/dev/null || true
  fi
  # DNS diagnostics: when the failure involves DNS resolution errors ("no such host" or
  # "dial tcp: lookup"), capture Route 53 record state and resolver output as artifacts.
  # This helps triage DNS propagation / hosted-zone issues without needing to reproduce.
  dns_pattern_found="no"
  if [[ -f "${ARTIFACT_DIR}/.install.log" ]] && grep -qE "no such host|dial tcp: lookup" "${ARTIFACT_DIR}/.install.log" 2>/dev/null; then
    dns_pattern_found="yes"
  elif echo "${status_desc}" | grep -qE "no such host|dial tcp: lookup" 2>/dev/null; then
    dns_pattern_found="yes"
  fi
  if [[ "${dns_pattern_found}" == "yes" ]]; then
    log "DNS-related error detected, capturing DNS diagnostics..."
    {
      echo "=== DNS Diagnostics ==="
      echo "Captured at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      echo "Cluster ID: ${CLUSTER_ID}"
      echo ""

      # Extract API URL and cluster DNS zone from the saved cluster description
      api_url=$(jq -r '.api.url // empty' "${ARTIFACT_DIR}/cluster-description.json" 2>/dev/null || true)
      cluster_name=$(jq -r '.name // empty' "${ARTIFACT_DIR}/cluster-description.json" 2>/dev/null || true)
      base_domain=$(jq -r '.dns.base_domain // empty' "${ARTIFACT_DIR}/cluster-description.json" 2>/dev/null || true)

      api_host=""
      if [[ -n "${api_url}" ]]; then
        api_host=$(echo "${api_url}" | sed -e 's|https\?://||' -e 's|:[0-9]*$||')
        echo "API URL: ${api_url}"
        echo "API hostname: ${api_host}"
      else
        echo "API URL not available in cluster description"
      fi

      cluster_zone=""
      if [[ -n "${cluster_name}" && -n "${base_domain}" ]]; then
        cluster_zone="${cluster_name}.${base_domain}"
        echo "Cluster DNS zone: ${cluster_zone}"
      fi
      echo ""

      # Resolve the API hostname via the default resolver (CoreDNS on the management cluster)
      if [[ -n "${api_host}" ]]; then
        echo "=== dig ${api_host} (default resolver) ==="
        dig "${api_host}" 2>&1 || true
        echo ""

        # Look up authoritative nameservers for the cluster zone and query them directly
        ns_zone="${cluster_zone:-$(echo "${api_host}" | cut -d. -f2-)}"
        echo "=== Authoritative NS lookup for ${ns_zone} ==="
        dig NS "${ns_zone}" +short 2>&1 || true
        echo ""
        auth_ns=$(dig NS "${ns_zone}" +short 2>/dev/null | head -1 || true)
        if [[ -n "${auth_ns}" ]]; then
          echo "=== dig @${auth_ns} ${api_host} (authoritative) ==="
          dig "@${auth_ns}" "${api_host}" 2>&1 || true
          echo ""
        else
          echo "No authoritative nameservers found for ${ns_zone}"
          echo ""
        fi
      fi

      # Route 53: dump the hosted-zone record sets for the cluster's DNS name
      if aws sts get-caller-identity &>/dev/null; then
        echo "=== Route 53 hosted zone records ==="
        if [[ -n "${cluster_zone}" ]]; then
          hz_json=$(aws route53 list-hosted-zones-by-name \
            --dns-name "${cluster_zone}" \
            --max-items 1 \
            --output json 2>/dev/null || true)
          hz_name=$(echo "${hz_json}" | jq -r '.HostedZones[0].Name // empty' 2>/dev/null || true)
          hz_id=$(echo "${hz_json}" | jq -r '.HostedZones[0].Id // empty' 2>/dev/null | sed 's|/hostedzone/||' || true)
          if [[ "${hz_name}" == "${cluster_zone}." ]]; then
            echo "Hosted zone: ${hz_name} (ID: ${hz_id})"
            aws route53 list-resource-record-sets \
              --hosted-zone-id "${hz_id}" \
              --output json 2>&1 || true
          else
            echo "No exact Route 53 hosted zone match for: ${cluster_zone} (closest: ${hz_name:-none})"
          fi
        else
          echo "Cluster DNS zone not available, skipping Route 53 lookup"
        fi
        echo ""
      else
        echo "=== Route 53 ==="
        echo "AWS credentials not available for Route 53 lookup"
        echo ""
      fi

      echo "=== End DNS Diagnostics ==="
      echo "Completed at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "${ARTIFACT_DIR}/dns-diagnostics.txt" 2>&1
    log "DNS diagnostics saved to ${ARTIFACT_DIR}/dns-diagnostics.txt"
  fi
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
if [[ "$HOSTED_CP" == "true" ]] && [[ "${INFRA_ID}" == "null" ]]; then
  # Currently, there is no infra_id for rosa hypershift cluster, use a fake one instead of null
  INFRA_ID=$(cat $cluster_info_json | jq -r '.name')
fi
echo "${INFRA_ID}" > "${SHARED_DIR}/infra_id"
