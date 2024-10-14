#!/bin/bash

set -x

# session variables
HC_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HC_NAME
job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export job_id
plugins_list=("vpc-infrastructure" "cloud-dns-services")
infra_name="hcp-ci-$job_id"
export infra_name
hcp_domain="$job_id-$HYPERSHIFT_BASEDOMAIN"
export hcp_domain
IC_API_KEY=$(cat "${AGENT_IBMZ_CREDENTIALS}/ibmcloud-apikey")
export IC_API_KEY
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
    curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/${IC_CLI_VERSION}/IBM_Cloud_CLI_${IC_CLI_VERSION}_amd64.tar.gz
    tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
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
dns_zone_id=$(ibmcloud dns zones -i $infra_name-dns | grep $HC_NAME.$hcp_domain | awk '{print $1}')
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

# Deleting the bastion VSI
echo "Triggering the $infra_name-bastion instance deletion in the $infra_name-vpc VPC."
bvsi_delete_status=$(ibmcloud is instance-delete $infra_name-bastion --output JSON -f | jq -r '.[]|.result')
if [ "$bvsi_delete_status" = 'false' ]; then
    echo "Deletion of $infra_name-bastion instance is not successful."
    exit 1
else 
    echo "Successfully deleted the $infra_name-bastion instance in the $infra_name-vpc VPC."
fi

# Clearing proxy setup as we deleted bastion ( proxy server )

rm -rf "${SHARED_DIR}/proxy-conf.sh"
unset http_proxy
unset https_proxy
unset HTTP_PROXY
unset HTTPS_PROXY
unset NO_PROXY
unset no_proxy

# Deleting the bastion VSI Floating IP
echo "Triggering the $infra_name-bastion-ip Floating IP in the $infra_name-rg resource group."
bfip_delete_status=$(ibmcloud is ipd $infra_name-bastion-ip --output JSON -f | jq -r '.[]|.result')
if [ "$bfip_delete_status" = 'false' ]; then
    echo "Deletion of $infra_name-bastion-ip floating IP is not successful."
    exit 1
else 
    echo "Successfully deleted the $infra_name-bastion-ip floating IP in the $infra_name-rg resource group."
fi

sleep 60   # Allowing all the subnet resources to get deleted


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

echo "Waiting for resources to get deleted completely before deleting the resource group"
sleep 60

# Deleting the resource group
set -e
rg_id=$(ibmcloud resource groups -q | awk -v rg="$infra_name-rg" '$1 == rg {print $2}')
echo "Resource Group ID: $rg_id"

echo "Verifying if any resource reclamations are present in the $infra_name-rg resource group"
instance_ids=$(ibmcloud resource reclamations --output json | jq -r --arg rid "$rg_id" '.[]|select(.resource_group_id == $rid)|.id' | tr '\n' ' ')
IFS=' ' read -ra instance_id_list <<< "$instance_ids"
if [ ${#instance_id_list[@]} -gt 0 ]; then
    echo "Reclamation Instance IDs :" "${instance_id_list[@]}"
    for instance_id in "${instance_id_list[@]}"; do
        echo "Deleting the reclamation instance id $instance_id"
        ibmcloud resource reclamation-delete $instance_id -f 
    done
else
    echo "No resource reclamations are present in $infra_name-rg"
fi

echo "Verifying if any service instances are present in the $infra_name-rg resource group"
si_names=$(ibmcloud resource service-instances --type all -g $infra_name-rg --output JSON | jq -r '.[]|.name' | tr '\n' ' ')
IFS=' ' read -ra si_list <<< "$si_names"
if [ ${#si_list[@]} -gt 0 ]; then
    echo "Service Instance Names :" "${si_list[@]}"
    for si in "${si_list[@]}"; do
        echo "Deleting the service instance $si"
        ibmcloud resource service-instance-delete $si -g $infra_name-rg --recursive -f
    done
else
    echo "No service instances are present in $infra_name-rg"
fi

echo "Triggering the $infra_name-rg resource group deletion in the $IC_REGION region."
ibmcloud resource group-delete $infra_name-rg -f
echo "Successfully completed the deletion of all the resources that are created during the CI."
echo "$(date) Successfully completed the e2e deletion chain"
