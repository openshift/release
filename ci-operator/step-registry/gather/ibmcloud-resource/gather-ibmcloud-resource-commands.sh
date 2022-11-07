#!/bin/bash

set -o nounset
set -o pipefail


# Make sure jq is installed
if ! command -v jq; then
    # TODO move to image
    curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/jq
    chmod +x /tmp/jq
fi

set -o errexit


RESOURCE_DUMP_DIR="${ARTIFACT_DIR}/ibmcloud-gather-resources"
CLUSTER_FILTER="${NAMESPACE}-${JOB_NAME_HASH}"
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

# Install IBM Cloud CLI and plugins
function install_ibmcloud_cli {
    # Download the latest IBM Cloud release binary
    latest_binary_url=$(curl -m 10 https://api.github.com/repos/IBM-Cloud/ibm-cloud-cli-release/releases/latest | /tmp/jq .body | sed 's,.*\[Linux 64 bit\](\(https://.*linux_amd64\.tgz\)).*,\1,g')
    curl -Lo "/tmp/IBM_Cloud_CLI.tgz" "${latest_binary_url}"
    # Extract binary and move to bin
    tar -C /tmp -xzf "/tmp/IBM_Cloud_CLI.tgz"
    export IBMCLOUD_CLI=/tmp/ibmcloud
    mv /tmp/IBM_Cloud_CLI/ibmcloud "${IBMCLOUD_CLI}"
    # Install required plugins
    "${IBMCLOUD_CLI}" plugin install cloud-object-storage
    "${IBMCLOUD_CLI}" plugin install vpc-infrastructure
    "${IBMCLOUD_CLI}" plugin install cloud-internet-services
}

# IBM Cloud CLI login
function ibmcloud_login {
    "${IBMCLOUD_CLI}" login -a https://cloud.ibm.com -r ${LEASED_RESOURCE} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

# Gather load-balancer resources
function gather_lb_resources {
    mapfile -t LBS < <("${IBMCLOUD_CLI}" is lbs -q | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter {print $1}')
    for lb in "${LBS[@]}"; do
        {
            echo -e "# ibmcloud is lb-ls ${lb}\n"
            "${IBMCLOUD_CLI}" is lb-ls "${lb}"
            echo -e "\n\n\n# ibmcloud is lb-l ${lb} <listener>\n"
            "${IBMCLOUD_CLI}" is lb-ls "${lb}" -q | sed 1d | awk '{print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} is lb-l ${lb} %"
            echo -e "\n\n\n# ibmcloud is lb-ps ${lb}\n"
            "${IBMCLOUD_CLI}" is lb-ps "${lb}"
            echo -e "\n\n\n# ibmcloud is lb-p ${lb} <pool>\n"
	    "${IBMCLOUD_CLI}" is lb-ps "${lb}" -q | sed 1d | awk '{print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} is lb-p ${lb} %"
        } > "${RESOURCE_DUMP_DIR}/load-balancer-${lb}.txt"
    done
}

# Gather vpc-routing-tables
function gather_vpc_routing_tables {
    local VPC
    VPC=$("${IBMCLOUD_CLI}" is vpcs | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter {print $1}')
    {
        echo -e "# ibmcloud is vpc-routing-tables ${VPC}\n"
        "${IBMCLOUD_CLI}" is vpc-routing-tables "${VPC}"
        echo -e "\n\n\n# ibmcloud is vpc-routing-table ${VPC} <table>\n"
        "${IBMCLOUD_CLI}" is vpc-routing-tables "${VPC}" -q | sed 1d | awk '{print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} is vpc-routing-table ${VPC} %; echo "
    } > "${RESOURCE_DUMP_DIR}/vpc-routing-tables.txt"
}

# Gather COS resources
function gather_cos {
    {
        echo -e "# ibmcloud resource service-instances --service-name cloud-object-storage\n"
        "${IBMCLOUD_CLI}" resource service-instances --service-name cloud-object-storage | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter'
        echo -e "\n\n\n# ibmcloud resource service-instance <cos>"
        "${IBMCLOUD_CLI}" resource service-instances --service-name cloud-object-storage | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter {print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} resource service-instance %"
    } > "${RESOURCE_DUMP_DIR}/cos.txt"

}

# Gather CIS resources
function gather_cis {
    local cisName BASE_DOMAIN
    if [ -f "${CLUSTER_PROFILE_DIR}/ibmcloud-cis" ]; then
        cisName="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-cis")"
        BASE_DOMAIN="$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-cis-domain")"
    else
        cisName="Openshift-IPI-CI-CIS"
        BASE_DOMAIN="ci-ibmcloud.devcluster.openshift.com"
    fi
    echo -e "#cisName: ${cisName}"
    command_retry "${IBMCLOUD_CLI}" cis instance-set ${cisName}

    echo -e "#baseDomain: ${BASE_DOMAIN}"
    DOMAIN_ID=$(command_retry "${IBMCLOUD_CLI}" cis domains | grep ${BASE_DOMAIN} | awk '{print $1}')
    {
        echo -e "# ibmcloud cis domains\n"
        command_retry "${IBMCLOUD_CLI}" cis domains --per-page 50 | awk -v filter="${DOMAIN_ID}" '$0 ~ filter'
	echo -e "## ibmcloud cis dns-records ${DOMAIN_ID}\n"
	# DNS Record Names do not contain the $JOB_NAME_HASH, so we filter on the $NAMESPACE only
	command_retry "${IBMCLOUD_CLI}" cis dns-records "${DOMAIN_ID}" | awk -v filter="${NAMESPACE}" '$0 ~ filter'
	echo -e "## ibmcloud cis dns-record ${DOMAIN_ID} <dns-record>\n"
	command_retry "${IBMCLOUD_CLI}" cis dns-records "${DOMAIN_ID}" | awk -v filter="${NAMESPACE}" '$0 ~ filter {print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} cis dns-record ${DOMAIN_ID} %"
    } > "${RESOURCE_DUMP_DIR}/cis.txt"
}

# Gather resources
function gather_resources {
    for resource in "${MAIN_RESOURCES[@]}"; do
        {
            echo -e "# ibmcloud is ${resource}s\n"
            "${IBMCLOUD_CLI}" is "${resource}s" -q | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter'
            echo -e "\n\n\n# ibmcloud is ${resource} <item>\n"
            "${IBMCLOUD_CLI}" is "${resource}s" -q | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter {print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} is ${resource} %"
        } > "${RESOURCE_DUMP_DIR}/${resource}s.txt"
    done

    # Run any additional resource collection requiring unique commands
    gather_lb_resources
    gather_vpc_routing_tables
    gather_cos
    gather_cis
}

install_ibmcloud_cli

# Disable exit on error for login
set +o errexit
login_success=false
for _ in $(seq 5); do
    if ibmcloud_login; then
        login_success=true
        break
    fi
    sleep 10
done
if [[ ${login_success} == false ]]; then
    echo "ERROR: Failed to log into IBM Cloud CLI."
    exit 1
fi

# Enable exit on error to short circuit if there are failures during gather
set -o errexit
mkdir -p "${RESOURCE_DUMP_DIR}"
gather_resources
