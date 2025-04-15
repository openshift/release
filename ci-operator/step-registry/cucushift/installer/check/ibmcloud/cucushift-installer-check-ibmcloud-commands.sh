#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# IBM Cloud CLI login
function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output
    region="${LEASED_RESOURCE}"
    export region
    "${IBMCLOUD_CLI}" config --check-version=false
    echo "Try to login..."
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

#OCP-47390 - [IPI-on-IBMCloud] Install cluster with "install-config.yaml" last step
function checkProviderType {
    local platformStatusFile="${ARTIFACT_DIR}/platformStatus"
    oc get infrastructure/cluster -o yaml > ${platformStatusFile}
    yq-go r ${platformStatusFile} 'status.platformStatus'
    providerType=$(yq-go r ${platformStatusFile} 'status.platformStatus.ibmcloud.providerType')
    if [[ ${providerType} != "VPC" ]]; then
        echo "ERROR: ${providerType} is not expected providerType [VPC]!!"
        return 1
    else 
        return 0
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function checkBootstrapResource() {
    local sub_command=$1 key_words=$2 additional_options=${3:--q} ret=0 output

    echo -e "\n**********Check bootstrap related resource ${sub_command}**********"
    output=$(run_command "${IBMCLOUD_CLI} is ${sub_command} ${additional_options}")
    if [[ "$output" == *"$key_words"* ]]; then
        echo -e "ERROR: related resource ${sub_command} is not destroyed.\n${output}"
        ret=1
    else
        echo "INFO: related resource ${sub_command} is destroyed."
    fi
    return ${ret}
}

function checkCOS() {
    local bucketName=$1
    local ret=0
    
    mapfile -t cosCRNs < <(${IBMCLOUD_CLI} resource service-instances --service-name cloud-object-storage -q --output JSON | jq -r .[].crn)
	if [ ${#cosCRNs[@]} -eq 0 ]; then
        echo "No COS instances found."
        ret=1
    else
        echo "Found ${#cosCRNs[@]} COS instances."
    fi

    for crn in "${cosCRNs[@]}"; do
      	echo "Processing COS instance with CRN: $crn ..."
		${IBMCLOUD_CLI} cos config crn --crn "${crn}" --force 

		output=$(${IBMCLOUD_CLI} cos config crn --list)
		if [[ "$output" != *"$crn"* ]]; then
			echo "ERROR: config the crn failed"
			ret=1
		fi
		
		output=$(${IBMCLOUD_CLI} cos bucket-location-get --bucket ${bucketName})
		echo "bucket-laction: $output"

		if [[ "$output" == *"OK"*  ]]; then
			echo "ERROR: related bucket is not destroyed."
			ret=1
		else
			echo "INFO: related bucket is destroyed."
		fi

    done

    return ${ret}
}

function checkIPs() {
	local ret=0 vmIPs=("$@")
    local lbs lb lbps pool ip mIPs
    echo "The reserved IPs of vms: " "${vmIPs[@]}"
    mapfile -t lbs < <(${IBMCLOUD_CLI} is load-balancers -q | awk '(NR>1) {print $2}')
	if [ ${#lbs[@]} -eq 0 ]; then
        echo "No load balances found."
        ret=1
    else
        echo "Found ${#lbs[@]} load-balancers. "
    fi

	for lb in "${lbs[@]}"; do
		echo "Processing load balances $lb ..."
        mapfile -t lbps < <(${IBMCLOUD_CLI} is load-balancer-pools $lb -q | awk '(NR>1) {print $1}') 
        if [ ${#lbps[@]} -eq 0 ]; then
            echo "No load balance pools found in $lb."
            ret=1
        else
            echo "Found ${#lbps[@]} load-balancer pools in $lb."
        fi
        
        for pool in "${lbps[@]}"; do
            echo -e "\tProcessing pool of load balance $lb: $pool ..."
            mapfile -t mIPs < <(${IBMCLOUD_CLI} is load-balancer-pool-members $lb $pool -q | awk '(NR>1) {print $3}')
            if [ ${#mIPs[@]} -eq 0 ]; then
                echo "No members of a load balancer $lb pool $pool."
            else
                echo "Found ${#mIPs[@]} members in load-balancer $lb pool $pool."
            fi

            for ip in "${mIPs[@]}"; do
                if [[ ! " ${vmIPs[*]} " =~ *" ${ip} "* ]]; then
                    echo "ERROR: The member target ip [${ip}] of the load balancer $lb pool $pool is not in the reserved IPs!"
                    ret=1
                fi
            done
        done
	done

    return ${ret}
}


if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
    echo "ERROR: fail to get the kubeconfig file under ${SHARED_DIR}!!"
    exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

check_result=0

checkProviderType ||  check_result=1

#==================== check the resources of bootstrap ================================
ibmcloud_login || check_result=1

infraID=$(jq -r .infraID "${SHARED_DIR}/metadata.json")
resourceGroup=$(jq -r .ibmcloud.resourceGroupName "${SHARED_DIR}/metadata.json")
region=$(jq -r .ibmcloud.region "${SHARED_DIR}/metadata.json")
${IBMCLOUD_CLI} target -g "${resourceGroup}" -r "${region}" || exit 1

bootstrap_host_name="${infraID}-bootstrap"

checkBootstrapResource "instances" "${bootstrap_host_name}" || check_result=1

checkBootstrapResource "security-groups" "${infraID}-security-group-bootstrap" || check_result=1

checkCOS "${bootstrap_host_name}-ignition" || check_result=1

mapfile -t ips < <(${IBMCLOUD_CLI} is instances -q | awk '(NR>1) {print $4}')
checkIPs "${ips[@]}" || check_result=1

#========================================================================================
if [[ ${check_result} -eq 0 ]]; then
	echo "Check PASS"
else
	echo "Check FAIL!!"
fi

exit ${check_result}