#!/bin/bash

set -x

# Agent hosted cluster configs
HOSTED_CLUSTER_NAME="$(printf $PROW_JOB_ID | sha256sum | cut -c-20)"
export HOSTED_CLUSTER_NAME
export HOSTED_CONTROL_PLANE_NAMESPACE="${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"

# Fetching Domain from Vault
if [[ -z "${HYPERSHIFT_BASE_DOMAIN}" ]]; then
		HYPERSHIFT_BASE_DOMAIN=$(jq -r '.hypershiftBaseDomain' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
fi

# Fetching Resource Group Name from Vault
if [[ -z "${RESOURCE_GROUP_NAME}" ]]; then
    RESOURCE_GROUP_NAME=$(jq -r '.resourceGroupName' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
fi

# Fetching CIS related details from Vault
if [[ -z "${CIS_INSTANCE}" ]]; then
		CIS_INSTANCE=$(jq -r '.cisInstance' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
fi
if [[ -z "${CIS_DOMAIN_ID}" ]]; then
		CIS_DOMAIN_ID=$(jq -r '.cisDomainID' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
fi

# Installing generic required tools
echo "$(date) Installing required tools"
mkdir /tmp/ibm_cloud_cli
curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.16.1/IBM_Cloud_CLI_2.16.1_amd64.tar.gz
tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
export PATH=$PATH:/tmp/bin

echo | ibmcloud login --apikey @"${AGENT_POWER_CREDENTIALS}/ibmcloud-apikey"
ibmcloud target -g "${RESOURCE_GROUP_NAME}"

# Installing required ibmcloud plugins
echo "$(date) Installing required ibmcloud plugins"
ibmcloud plugin install vpc-infrastructure
ibmcloud plugin install cis
ibmcloud cis instance-set ${CIS_INSTANCE}

set_lb_configs() {
	# LoadBalancer configs
	LB_NAME="lb-${HOSTED_CLUSTER_NAME}"
	LB_ID=""

	# Other resource configs
	IP_X86=$(cat ${SHARED_DIR}/ipx86addr)
	IP_POWER=$(cat ${SHARED_DIR}/ippoweraddr)

	# Fetch VPC details
	if [[ -z "${VPC_REGION}" ]]; then
		VPC_REGION=$(jq -r '.vpcRegion' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
	fi
	if [[ -z "${VPC_NAME}" ]]; then
		VPC_NAME=$(jq -r '.vpcName' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
	fi
	if [[ -z "${VPC_SUBNET_ID}" ]]; then
		VPC_SUBNET_ID=$(jq -r '.vpcSubnetID' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
	fi
}

dns_entry() {
	# Create DNS entry
	LB_ID=$1

	# Clean up the record previously created with worker IP.
	idToDelete=$(ibmcloud cis dns-records ${CIS_DOMAIN_ID} --name "*.apps.${HOSTED_CLUSTER_NAME}.${HYPERSHIFT_BASE_DOMAIN}" --output json | jq -r '.[].id')
	if [ -n "${idToDelete}" ]; then
		ibmcloud cis dns-record-delete ${CIS_DOMAIN_ID} ${idToDelete}
	fi

	LB_HOSTNAME=$(ibmcloud is load-balancer "${LB_ID}" --output JSON | jq -r '.hostname')
	# Create a new record with lb
	ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type CNAME --name "*.apps.${HOSTED_CLUSTER_NAME}" --content "${LB_HOSTNAME}"
}

wait_lb_active() {
	INTERVAL=$1
	TIMEOUT=$2
	ELAPSED=0

	while true; do
		LB_STATE=$(ibmcloud is load-balancer "${LB_ID}" --output JSON | jq -r '.provisioning_status')

		if [ "$LB_STATE" == "active" ]; then
			echo "Load balancer is active."
			break
		fi

		if [ $ELAPSED -ge $TIMEOUT ]; then
			echo "Timeout reached while waiting for load balancer to become active."
			return 1
		fi

		sleep "${INTERVAL}"
		ELAPSED=$((ELAPSED + INTERVAL))
	done
}


attach_server() {
	TARGET_IP=$1
	POOL_ID=$2
	POOL_PORT=$3
	ibmcloud is load-balancer-pool-member-create "${LB_ID}" "${POOL_ID}" "${POOL_PORT}" "${TARGET_IP}"
	wait_lb_active 30 600
}

provision_backend_pool() {
	POOL_NAME=$1
	POOL_PORT=$2
	# Create pool
	POOL_ID=$(ibmcloud is load-balancer-pool-create "${POOL_NAME}" "${LB_ID}" round_robin tcp 5 2 2 tcp --health-monitor-port "${POOL_PORT}" --output JSON | jq -r '.id')
	# attach servers
	IFS=' ' read -r -a ips <<<"${IP_X86}"
	for ip in "${ips[@]}"; do
		attach_server $ip "${POOL_ID}" "${POOL_PORT}"
	done
	IFS=' ' read -r -a ips <<<"${IP_POWER}"
	for ip in "${ips[@]}"; do
		attach_server $ip "${POOL_ID}" "${POOL_PORT}"
	done
	# Create Frontend listener
	ibmcloud is load-balancer-listener-create "${LB_ID}" --port "${POOL_PORT}" --protocol tcp --default-pool "${POOL_ID}"
}

update_security_groups() {
    # Fetch private IP addresses of the Load Balancer
    LB_PRIVATE_IPS=$(ibmcloud is load-balancer "${LB_ID}" --output JSON | jq -r '.private_ips[].address')

    # Retrieve the security group ID associated with the Load Balancer
    SECURITY_GROUP_ID=$(ibmcloud is load-balancer "${LB_ID}" --output JSON | jq -r '.security_groups[].id')
    # Add inbound rules to allow traffic from the Load Balancer for ports 80 and 443
	RULE_ID=()
    for ip in $LB_PRIVATE_IPS; do
        for port in 80 443; do
            echo "Adding security group rule for IP $ip on port $port"
            rule_id=$(ibmcloud is security-group-rule-add "${SECURITY_GROUP_ID}" inbound tcp --local "$ip" --port-min "$port" --port-max "$port" --output JSON | jq -r '.id')
			RULE_ID+=("$rule_id")
        done
    done
	# Save rule ids to ${SHARED_DIR} to be used in destroy step later
	echo "${RULE_ID[@]}" > "${SHARED_DIR}/rule_id"
}

provision_lb() {
	if [ -n "${1:-}" ] && [ "$1" == "glb" ]; then
		origins=$(sed 's/,$//' "${SHARED_DIR}/origins")
		origin_pools_json="{\"name\": \"${HOSTED_CLUSTER_NAME}\", \"origins\": [${origins}]}"

		pool_id=$(ibmcloud cis glb-pool-create -i ${CIS_INSTANCE} --json "${origin_pools_json}" --output json | jq -r '.id')

		lb_name="${HOSTED_CLUSTER_NAME}.${HYPERSHIFT_BASE_DOMAIN}"
		lb_payload="{\"name\": \"${lb_name}\",\"fallback_pool\": \"${pool_id}\",\"default_pools\": [\"${pool_id}\"]}"

		ibmcloud cis glb-create ${CIS_DOMAIN_ID} -i ${CIS_INSTANCE} --json "${lb_payload}"

		# Creating dns record for ingress
		echo "$(date) Creating dns record for ingress"
		ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type CNAME --name "*.apps.${HOSTED_CLUSTER_NAME}" --content "${lb_name}"
		return
	fi
	# Create Load Balancer
	LB_ID=$(ibmcloud is load-balancer-create "${LB_NAME}" public --vpc "${VPC_NAME}" --subnet "${VPC_SUBNET_ID}" --resource-group-name "${RESOURCE_GROUP_NAME}" --family application --output JSON | jq -r '.id')
	wait_lb_active 300 600
	echo "Load Balancer created!"
	# Create Backend pools
	provision_backend_pool "http" "80"
	wait_lb_active 30 600
	provision_backend_pool "https" "443"
	# Update security groups to allow traffic through LB
	update_security_groups
}

update_dns_records() {
	HOSTED_CLUSTER_API_SERVER=$(oc get service kube-apiserver -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.loadBalancer.ingress[].hostname')
	IFS=' ' read -r -a IP_ADDRESSES <<< "$(cat ${SHARED_DIR}/ippoweraddr)"

	# Creating dns records in ibmcloud cis service for agents to reach hosted cluster
	ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type CNAME --name "api.${HOSTED_CLUSTER_NAME}" --content "${HOSTED_CLUSTER_API_SERVER}"
	ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type CNAME --name "api-int.${HOSTED_CLUSTER_NAME}" --content "${HOSTED_CLUSTER_API_SERVER}"

	if [ "${USE_GLB}" == "yes" ]; then
		provision_lb "glb"
	elif [ "${USE_GLB}" == "no" ]; then
		echo "$(date) GLB not created, so assigning first node's ip to ingress dns record"
		ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type A --name "*.apps.${HOSTED_CLUSTER_NAME}" --content "${IP_ADDRESSES[0]}"
	else
		echo "DNS record entry for *.apps.${HOSTED_CLUSTER_NAME} not added."
	fi
}

main() {
	update_dns_records
	if [ ${IS_HETEROGENEOUS} == "no" ]; then
		exit
	fi
	set_lb_configs
	ibmcloud target -r "${VPC_REGION}"
	# Creating LB and attaching targets
	provision_lb
	# Creating dns record for ingress
	dns_entry "${LB_ID}"
}

main
