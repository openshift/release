#!/bin/bash
function debug_on_failure() {
    local exit_code=$?
    # Only sleep if the exit code is non-zero (failure)
    if [ $exit_code -ne 0 ]; then
        echo "Script failed with exit code $exit_code. Sleeping for 2 hours for debugging purposes."
        sleep 2s
    fi
}

trap debug_on_failure EXIT ERR

set -o nounset
set -o pipefail
set -o errexit

RESOURCE_DUMP_DIR="${ARTIFACT_DIR}"
CLUSTER_FILTER="${NAMESPACE}-${UNIQUE_HASH}"
declare -a MAIN_RESOURCES=(floating-ip image instance lb public-gateway sg subnet volume vpc)


RETRY_ATTEMPTS=5
RETRY_SLEEP=10

# Retry commands to prevent intermittent flakes from causing failure
function command_retry {
    local cmd base_command command_successful temp_results errexit temp_status
    cmd=$1
    shift

    command_successful=false
    # Remove any filepaths from the command to be called for temporary results filename
    base_command=$(basename "${cmd}")
    temp_results=$(mktemp "/tmp/${base_command}_retry_results-XXXXXX")
    temp_status=$(mktemp /tmp/errexit_status-XXXXXX)

    # stash the current errexit setting to restore after we disable for command retry loop
    set +o | grep errexit > "${temp_status}"
    errexit=$(cat "${temp_status}")
    rm "${temp_status}"

    # Disable exit on error to allow for command retries
    set +e

    for _ in $(seq "${RETRY_ATTEMPTS}"); do
        if "${cmd}" "${@}" > "${temp_results}"; then
            command_successful=true
	    break
        fi
	sleep "${RETRY_SLEEP}"
    done

    # Restore exit on error setting
    ${errexit}
    # Write captured stdout results of command to stdout
    cat "${temp_results}"

    # Check if command eventually was successful
    if [[ "${command_successful}" == "true" ]]; then
        return 0
    fi
    echo "ERROR: Failure to perform: ${cmd} ${*}"
    return 1
}

# IBM Cloud CLI login
function ibmcloud_login {
  export IBMCLOUD_CLI=ibmcloud
  export IBMCLOUD_HOME=/output
  region="${LEASED_RESOURCE}"
  export region
  "${IBMCLOUD_CLI}" config --check-version=false
  echo "Try to login..."
  if [ -f "${SHARED_DIR}/ibmcloud-min-permission-api-key" ]; then
      "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${SHARED_DIR}/ibmcloud-min-permission-api-key" -q
  else
      "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key" -q
  fi
}


# Gather load-balancer resources
function gather_lb_resources {
    mapfile -t LBS < <("${IBMCLOUD_CLI}" is lbs -q | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter {print $1}')
    for lb in "${LBS[@]}"; do
        {
            echo -e "# ibmcloud is lb-ls ${lb}\n"
            "${IBMCLOUD_CLI}" is lb-ls "${lb}" -q
            echo -e "\n\n\n# ibmcloud is lb-l ${lb} <listener>\n"
            "${IBMCLOUD_CLI}" is lb-ls "${lb}" -q | sed 1d | awk '{print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} is lb-l ${lb} % -q"
            echo -e "\n\n\n# ibmcloud is lb-ps ${lb}\n"
            "${IBMCLOUD_CLI}" is lb-ps "${lb}"
            echo -e "\n\n\n# ibmcloud is lb-p ${lb} <pool>\n"
            "${IBMCLOUD_CLI}" is lb-ps "${lb}" -q | sed 1d | awk '{print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} is lb-p ${lb} % -q"
            echo -e "\n\n\n# ibmcloud is lb-pms ${lb} <pool>\n"
            "${IBMCLOUD_CLI}" is lb-ps "${lb}" -q | sed 1d | awk '{print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} is lb-pms ${lb} % -q"
        } > "${RESOURCE_DUMP_DIR}/load-balancer-${lb}.txt"
    done
}

# Gather vpc-routing-tables
function gather_vpc_routing_tables {
    local VPC
    VPC=$("${IBMCLOUD_CLI}" is vpcs -q| awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter {print $1}')
    {
        echo -e "# ibmcloud is vpc-routing-tables ${VPC}\n"
        "${IBMCLOUD_CLI}" is vpc-routing-tables "${VPC}" -q
        echo -e "\n\n\n# ibmcloud is vpc-routing-table ${VPC} <table>\n"
        "${IBMCLOUD_CLI}" is vpc-routing-tables "${VPC}" -q | sed 1d | awk '{print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} is vpc-routing-table ${VPC} % -q; echo "
    } > "${RESOURCE_DUMP_DIR}/vpc-routing-tables.txt"
}

# Gather COS resources
function gather_cos {
    {
        echo -e "# ibmcloud resource service-instances --service-name cloud-object-storage\n"
        "${IBMCLOUD_CLI}" resource service-instances --service-name cloud-object-storage -q| awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter'
        echo -e "\n\n\n# ibmcloud resource service-instance <cos>"
        "${IBMCLOUD_CLI}" resource service-instances --service-name cloud-object-storage | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter {print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} resource service-instance % -q"
    } > "${RESOURCE_DUMP_DIR}/cos.txt"

}

# Gather CIS resources
function gather_cis {
    echo -e "#ibmcloud_cis_instance_name: ${ibmcloud_cis_instance_name}\n"
    command_retry "${IBMCLOUD_CLI}" cis instance-set ${ibmcloud_cis_instance_name}

    if [[ -z "${BASE_DOMAIN}" ]]; then
        # Default the baseDomain if it hasn't been set, to the CI domain.
        BASE_DOMAIN="ci-ibmcloud.devcluster.openshift.com"
    fi

    echo -e "#baseDomain: ${BASE_DOMAIN}\n"
    cmd="${IBMCLOUD_CLI} cis domains -i ${ibmcloud_cis_instance_name} -o json | jq -r --arg n ${BASE_DOMAIN} '.[] | select(.name==\$n) | .id'"
    DOMAIN_ID=$(eval "${cmd}")
    if [[ -z "${DOMAIN_ID}" ]] ; then
        echo "Debug: Did not find the cis domain id of ${BASE_DOMAIN}"
        run_command "${IBMCLOUD_CLI} cis domains"
    else 
    {
        echo -e "## ibmcloud cis dns-records ${DOMAIN_ID}\n"
        # DNS Record Names do not contain the $UNIQUE_HASH, so we filter on the $NAMESPACE only
        command_retry "${IBMCLOUD_CLI}" cis dns-records "${DOMAIN_ID}" -q | awk -v filter="${NAMESPACE}" '$0 ~ filter'
        echo -e "## ibmcloud cis dns-record ${DOMAIN_ID} <dns-record>\n"
        command_retry "${IBMCLOUD_CLI}" cis dns-records "${DOMAIN_ID}" -q | awk -v filter="${NAMESPACE}" '$0 ~ filter {print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} cis dns-record ${DOMAIN_ID} % -q"
    } > "${RESOURCE_DUMP_DIR}/cis.txt"
    fi
}

function gather_dns() {
    echo "IBMCLOUD_DNS_INSTANCE_NAME: $IBMCLOUD_DNS_INSTANCE_NAME, BASE_DOMAIN: $BASE_DOMAIN"
    if [ ! -z ${IBMCLOUD_DNS_INSTANCE_NAME} ] && [ ! -z ${BASE_DOMAIN} ]; then
        cmd="${IBMCLOUD_CLI} dns zones -i ${IBMCLOUD_DNS_INSTANCE_NAME} -o json | jq -r --arg n ${BASE_DOMAIN} '.[] | select(.name==\$n) | .id'"
        dns_zone_id=$(eval "${cmd}")
        if [[ -z "${dns_zone_id}" ]]; then
            echo "Debug: Did not find dns_zone_id per the output of '${cmd}'"
        else
        {
            echo -e "created dns resource-records...\n"
            set +e
            cmd="${IBMCLOUD_CLI} dns resource-records ${dns_zone_id} -i ${IBMCLOUD_DNS_INSTANCE_NAME} | grep -w ${CLUSTER_FILTER}"
            count=$(eval "${cmd} -c")
            set -e
            if [ "${count}" -gt 0 ]; then
                run_command "${cmd}"
            fi

            echo -e "The permitted-networks: \n"
            cmd="${IBMCLOUD_CLI} dns permitted-networks ${dns_zone_id} -i ${IBMCLOUD_DNS_INSTANCE_NAME}"
            run_command "${cmd}"
        }  > "${RESOURCE_DUMP_DIR}/dns.txt"
        fi
    else
        run_command "${IBMCLOUD_CLI} dns instances -q"
    fi
}

# Gather resources
function gather_resources {
    local hasSetTarget=false
    for resource in "${MAIN_RESOURCES[@]}"; do
        {
            echo -e "# ibmcloud is ${resource}s\n"
            if [[ ${resource} == "image" ]] && [[ ! -z $RESOURCE_GROUP ]]; then
                "${IBMCLOUD_CLI}" target -g ${RESOURCE_GROUP} -q
                hasSetTarget=true
            fi
            "${IBMCLOUD_CLI}" is "${resource}s" -q | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter'
            echo -e "\n\n\n# ibmcloud is ${resource} <item>\n"
            "${IBMCLOUD_CLI}" is "${resource}s" -q | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter {print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} is ${resource} % -q"
        } > "${RESOURCE_DUMP_DIR}/${resource}s.txt"
        
        if [ "$hasSetTarget" = true ];  then
            ${IBMCLOUD_CLI} target --unset-resource-group
        fi
    done

    # Run any additional resource collection requiring unique commands
    gather_lb_resources
    gather_vpc_routing_tables
    gather_cos
    gather_cis
    gather_dns
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

check_instance_ssh() {
  local ssh_user="core"
  local bastion_user="core"
  local ssh_key="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  local proxy_ip=""
  if [[ -f "${SHARED_DIR}/proxyip" ]]; then
    proxy_ip="$(cat "${SHARED_DIR}/proxyip")"
  fi

  if [[ ! -s "$ssh_key" ]]; then
    echo "FAILED: Key $ssh_key does not exist."
    return 1
  fi

  if [ -s "${SHARED_DIR}/bastion_ssh_user" ]; then
    bastion_user="$(< "${SHARED_DIR}/bastion_ssh_user" )"
  fi
  # Ensure the key is added to the agent for forwarding
  if ! whoami &> /dev/null; then
    if [ -w /etc/passwd ]; then
      echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
  fi
  eval "$(ssh-agent)"
  ssh-add "$ssh_key"

  echo "Gathering instances from IBM Cloud..."
  local instances
  "${IBMCLOUD_CLI}" target -g ${RESOURCE_GROUP} -q
  instances=$(ibmcloud is instances --output JSON | jq -r '.[] | "\(.name)|\(.network_interfaces[0].primary_ip.address)|\(.status)"')

  if [[ -z "$instances" ]]; then
    echo "No instances found in the resource group."
    return 0
  fi

  echo "------------------------------------------------------------------------------"
  printf "%-35s | %-15s | %-10s\n" "NODE NAME" "INTERNAL IP" "RESULT"
  echo "------------------------------------------------------------------------------"

  for entry in $instances; do
    local node_name, node_ip, status
    node_name=$(echo "$entry" | cut -d'|' -f1)
    node_ip=$(echo "$entry" | cut -d'|' -f2)
    status=$(echo "$entry" | cut -d'|' -f3)

    if [[ "$status" != "running" ]]; then
      printf "%-35s | %-15s | [SKIP - %s]\n" "$node_name" "$node_ip" "$status"
      continue
    fi

    if [[ "$node_name" == "*bastion" ]]; then
      printf "%-35s | %-15s | [SKIP - bastion node]\n" "$node_name" "$node_ip"
      continue
    fi
    local ssh_args=(-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$ssh_key")

    # Add Jump Host if bastion exists
    if [[ -n "$proxy_ip" ]]; then
        ssh_args+=(-J "${bastion_user}@${proxy_ip}")
    fi

   if ssh "${ssh_args[@]}" "${ssh_user}@${node_ip}" "exit 0" > /dev/null 2>&1; then
      printf "%-35s | %-15s | [PASS]\n" "$node_name" "$node_ip"
    else
      printf "%-35s | %-15s | [FAIL]\n" "$node_name" "$node_ip"
    fi

  done
  echo "------------------------------------------------------------------------------"
}

ibmcloud_login

##in order to avoid "runtime error: invalid memory address or nil pointer dereference in 'ibmcloud is images -q'"
if [ -f ${SHARED_DIR}/metadata.json ]; then
    RESOURCE_GROUP=$(jq -r .ibmcloud.resourceGroupName ${SHARED_DIR}/metadata.json)
    echo "Resource group: $RESOURCE_GROUP"
elif [ -s "${SHARED_DIR}/ibmcloud_cluster_resource_group" ]; then
    RESOURCE_GROUP=$(cat "${SHARED_DIR}/ibmcloud_cluster_resource_group")
    echo "Resource group: $RESOURCE_GROUP"    
elif [ -s "${SHARED_DIR}/ibmcloud_resource_group" ]; then
    RESOURCE_GROUP=$(cat "${SHARED_DIR}/ibmcloud_resource_group")
    echo "Resource group: $RESOURCE_GROUP"
fi

if [ -f "${CLUSTER_PROFILE_DIR}/ibmcloud-cis" ]; then
    ibmcloud_cis_instance_name="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-cis")"
else
    #dev env variable
    ibmcloud_cis_instance_name="Openshift-IPI-CI-CIS"
fi

mkdir -p "${RESOURCE_DUMP_DIR}"
gather_resources

echo "==== Check the instance SSH connectivity ... ========="

set -o xtrace
check_instance_ssh

echo "==== IBM Cloud resource gathering completed. ========="