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
CLUSTER_FILTER="${NAMESPACE}-${UNIQUE_HASH}"
declare -a MAIN_RESOURCES=(floating-ip image instance lb public-gateway sg subnet volume vpc)

# Plugin power-iaas is required for the Powervs environment
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
    "${IBMCLOUD_CLI}" plugin install power-iaas
}

# IBM Cloud CLI login
function ibmcloud_login {
    # TODO(cjschaef): Retrieve target region from $LEASED_RESOURCE
    "${IBMCLOUD_CLI}" login -a https://cloud.ibm.com -r eu-gb --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
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
        "${IBMCLOUD_CLI}" resource service-instances --service-name cloud-object-storage | grep "${CLUSTER_FILTER}"
        echo -e "\n\n\n# ibmcloud resource service-instance <cos>"
        "${IBMCLOUD_CLI}" resource service-instances --service-name cloud-object-storage | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter {print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} resource service-instance %"
    } > "${RESOURCE_DUMP_DIR}/cos.txt"

}

# Gather CIS resources
function gather_cis {
    "${IBMCLOUD_CLI}" cis instance-set "Openshift-IPI-CI-CIS"
    DOMAIN_ID=$("${IBMCLOUD_CLI}" cis domains --per-page 50 | awk '/ci-ibmcloud.devcluster.openshift.com/{print $1}')
    {
        echo -e "# ibmcloud cis domains\n"
        "${IBMCLOUD_CLI}" cis domains --per-page 50 | awk -v filter="${DOMAIN_ID}" '$0 ~ filter {print $1}'
	echo -e "## ibmcloud cis dns-records ${DOMAIN_ID}\n"
	"${IBMCLOUD_CLI}" cis dns-records "${DOMAIN_ID}" | grep "${CLUSTER_FILTER}"
	echo -e "## ibmcloud cis dns-record ${DOMAIN_ID} <dns-record>\n"
	"${IBMCLOUD_CLI}" cis dns-records "${DOMAIN_ID}" | awk -v filter="${CLUSTER_FILTER}" '$0 ~ filter {print $1}' | xargs -I % sh -c "${IBMCLOUD_CLI} cis dns-record ${DOMAIN_ID} %"
    } > "${RESOURCE_DUMP_DIR}/cis.txt"
}

# Gather resources
function gather_resources {
    for resource in "${MAIN_RESOURCES[@]}"; do
        {
            echo -e "# ibmcloud is ${resource}s\n"
            "${IBMCLOUD_CLI}" is "${resource}s" -q | grep "${CLUSTER_FILTER}"
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
