#!/bin/bash

set -x

# session variables
infra_name="hcp-ci-$(echo -n $PROW_JOB_ID|cut -c-8)"
plugins_list=("vpc-infrastructure" "cloud-dns-services")
hc_name="agent-ibmz"
IC_API_KEY=$(cat "${AGENT_IBMZ_CREDENTIALS}/ibmcloud-apikey")
export IC_API_KEY
httpd_vsi_key="${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-key"
export httpd_vsi_key
httpd_vsi_ip=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-ip")
export httpd_vsi_ip

# Installing CLI tools
set -e
echo "Installing required CLI tools"
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
PATH=$PATH:/tmp/bin
export PATH
set +e
echo "Checking if ibmcloud CLI is installed."
ibmcloud -v
if [ $? -eq 0 ]; then
    echo "ibmcloud CLI is already installed."
else
    set -e
    echo "ibmcloud CLI is not installed. Installing it now..."
    mkdir /tmp/ibm_cloud_cli
    curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/${IC_CLI_VERSION}/IBM_Cloud_CLI_${IC_CLI_VERSION}_linux_amd64.tgz
    tar -xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
    export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
    set +e
fi 

# Login to the IBM Cloud
echo "Logging into IBM Cloud in the $IC_REGION region and $infra_name-rg resource group."
ibmcloud config --check-version=false                               # To avoid manual prompt for updating CLI version
ibmcloud login --apikey $IC_API_KEY -r $IC_REGION -g $infra_name-rg
echo "Installing the required ibmcloud plugins if not present."
for plugin in "${plugins_list[@]}"; do  
  ibmcloud plugin list -q | grep $plugin
  if [ $? -ne 0 ]; then
    echo "$plugin plugin is not installed. Installing it now..."
    ibmcloud plugin install $plugin -f
    echo "$plugin plugin is installed successfully."
  else 
    echo "$plugin plugin is already installed."
  fi
done

# Deleting the DNS Service
echo "Triggering the $infra_name-dns DNS instance deletion in the resource group $infra_name-rg."
dns_zone_id=$(ibmcloud dns zones -i $infra_name-dns | grep $hc_name.$HYPERSHIFT_BASEDOMAIN | awk '{print $1}')
glb_id=$(ibmcloud dns glbs $dns_zone_id -i $infra_name-dns --output json | jq -r '.[]|.id')
glb_pool_id=$(ibmcloud dns glb-pools -i $infra_name-dns --output json | jq -r '.[]|.id')
network_id=$(ibmcloud is vpc $infra_name-vpc --output JSON | jq -r '.id')
ibmcloud dns glb-delete $dns_zone_id $glb_id -i $infra_name-dns -f
ibmcloud dns glb-pool-delete $glb_pool_id -i $infra_name-dns -f
ibmcloud dns permitted-network-remove $dns_zone_id $network_id -i $infra_name-dns -f 
ibmcloud dns instance-delete $infra_name-dns -f
echo "Successfully deleted the DNS instance $infra_name-dns from the resource group $infra_name-rg."
set +e

# Deleting the zVSIs and Floating IPs
for ((i = 0; i < $HYPERSHIFT_NODE_COUNT ; i++)); do
    echo "Triggering the $infra_name-compute-$i instance deletion in the $infra_name-vpc VPC."
    vsi_status=$(ibmcloud is instance-delete $infra_name-compute-$i --output JSON -f | jq -r '.[]|.result')
    vsi_delete_status+=("$vsi_status")
    echo "Triggering the $infra_name-compute-$i-ip Floating IP in the $infra_name-rg resource group."
    fip_status=$(ibmcloud is ipd $infra_name-compute-$i-ip --output JSON -f | jq -r '.[]|.result')
    fip_delete_status+=("$fip_status")
done

for status in "${vsi_delete_status[@]}"; do
    if [ "$status" = 'false' ]; then
        echo "$infra_name-compute instances are not deleted successfully in the $infra_name-vpc VPC."
        exit 1
    else 
        echo "Successfully deleted the $infra_name-compute instances in the $infra_name-vpc VPC."
    fi
done

for status in "${fip_delete_status[@]}"; do
    if [ "$status" = 'false' ]; then
        echo "$infra_name-compute-ip floating IPs are not deleted successfully in the $infra_name-rg resource group."
        exit 1
    else 
        echo "Successfully deleted the $infra_name-compute-ip floating IPs in the $infra_name-rg resource group."
    fi
done

# Deleting the subnet
echo "Triggering the $infra_name-sn subnet deletion in the $infra_name-vpc VPC."
sn_delete_status=$(ibmcloud is subnet-delete $infra_name-sn --vpc $infra_name-vpc --output JSON -f | jq -r '.[]|.result')
if [ $sn_delete_status == "true" ]; then
    echo "Successfully deleted the subnet $infra_name-sn in the $infra_name-vpc VPC."
else 
    echo "Error: Failed to delete the $infra_name-sn subnet in the $infra_name-vpc VPC."
    exit 1
fi

# Deleting the VPC
echo "Triggering the $infra_name-vpc VPC deletion in the $infra_name-rg resource group."
vpc_delete_status=$(ibmcloud is vpc-delete $infra_name-vpc --output JSON -f | jq -r '.[]|.result')
if [ $vpc_delete_status == "true" ]; then
    echo "Successfully deleted the VPC $infra_name-vpc in the $infra_name-rg resource group."
else 
    echo "Error: Failed to delete the $infra_name-vpc VPC in the $infra_name-rg resource group."
    exit 1
fi

# Deleting the SSH key
echo "Triggering the $infra_name-key SSH key deletion in the resource group $infra_name-rg resource group."
ssh_key_delete_status=$(ibmcloud is key-delete $infra_name-key --output JSON -f | jq -r '.[]|.result')
if [ $ssh_key_delete_status == "true" ]; then
    echo "Successfully deleted the SSH key $infra_name-key in the $infra_name-rg resource group."
else 
    echo "Error: Failed to delete the $infra_name-key SSH key in the $infra_name-rg resource group."
    exit 1
fi

# Deleting the resource group
set -e
echo "Triggering the $infra_name-rg resource group deletion in the $IC_REGION region."
ibmcloud resource group-delete $infra_name-rg -f
echo "Successfully completed the destruction of all the resources that are created during the CI."

# Deleting the rootfs image from the HTTPD server
ssh -o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -i $httpd_vsi_key root@$httpd_vsi_ip "rm -rf /var/www/html/rootfs.img"
set +e
