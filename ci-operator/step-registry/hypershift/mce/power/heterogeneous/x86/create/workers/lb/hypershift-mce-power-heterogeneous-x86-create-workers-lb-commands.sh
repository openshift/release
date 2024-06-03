#!/bin/bash

set -x

# Agent hosted cluster configs
HOSTED_CLUSTER_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HOSTED_CLUSTER_NAME

# LoadBalancer configs
LB_NAME="${HOSTED_CLUSTER_NAME}-lb"
LB_ID=""

# Other resource configs
IP_X86=$(cat ${SHARED_DIR}/ipx86addr)
IP_POWER=$(cat ${SHARED_DIR}/ippoweraddr)

dns_entry() {
    # Create DNS entery
    LB_ID=$1
    ibmcloud plugin install cis
    ibmcloud cis instance-set ${CIS_INSTANCE}
    LB_HOSTNAME=$(ibmcloud is load-balancer "${LB_ID}" --output JSON | jq -r '.hostname')
    echo $LB_HOSTNAME
    ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type CNAME --name "*.apps.${HOSTED_CLUSTER_NAME}" --content "${LB_HOSTNAME}"
}

wait_lb_active() {
    INTERVAL=$1
    while true
    do
        LB_STATE=$(ibmcloud is load-balancer "${LB_ID}" --output JSON | jq -r '.provisioning_status')
        if [ $LB_STATE == "active" ]; then
            break
        fi
        sleep "${INTERVAL}"
    done
}

attach_server() {
    TARGET_IP=$1
    POOL_ID=$2
    POOL_PORT=$3
    ibmcloud is load-balancer-pool-member-create "${LB_ID}" "${POOL_ID}" "${POOL_PORT}" "${TARGET_IP}"
    wait_lb_active 30
}

provision_backend_pool() {
    POOL_NAME=$1
    POOL_PORT=$2
    # Create pool
    POOL_ID=$(ibmcloud is load-balancer-pool-create "${POOL_NAME}" "${LB_ID}" round_robin tcp 5 2 2 tcp --health-monitor-port "${POOL_PORT}" --output JSON | jq -r '.id')
    # attach servers
    IFS=' ' read -r -a ips <<< "${IP_X86}"
    for ip in "${ips[@]}"; do
        attach_server $ip "${POOL_ID}" "${POOL_PORT}"
    done
    IFS=' ' read -r -a ips <<< "${IP_POWER}"
    for ip in "${ips[@]}"; do
        attach_server $ip "${POOL_ID}" "${POOL_PORT}"
    done
    # Create Frontend listener
    ibmcloud is load-balancer-listener-create "${LB_ID}" --port "${POOL_PORT}" --protocol tcp --default-pool "${POOL_ID}"
}

provision_lb(){
    # Create Load Balancer
    LB_ID=$(ibmcloud is load-balancer-create "${LB_NAME}" public --vpc "${VPC_NAME}" --subnet "${VPC_SUBNET_ID}" --resource-group-name "${RESOURCE_GROUP_NAME}" --family application --output JSON | jq -r '.id')
    wait_lb_active 300
    echo "Load Balancer created!"
    # Create Backend pools
    provision_backend_pool "http" "80"
    wait_lb_active 30
    provision_backend_pool "https" "443"
}

# IBM cloud login
echo | ibmcloud login --apikey @"${AGENT_POWER_CREDENTIALS}/ibmcloud-apikey" -r "${VPC_REGION}"

# Target resource group
ibmcloud target -g "${RESOURCE_GROUP_NAME}"

# Install vpc plugin
ibmcloud plugin install vpc-infrastructure

# Creating LB and attaching targets
provision_lb

# Creating dns record for ingress
dns_entry "${LB_ID}"
