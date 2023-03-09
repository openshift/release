#!/bin/bash

set -exuo pipefail

rg_name="$IC_INFRA_NAME-rg"
ssh_key_name="$IC_INFRA_NAME-key"
vpc_name="$IC_INFRA_NAME-vpc"
sn_name="$IC_INFRA_NAME-sn"
rhel_vsi_name="$IC_INFRA_NAME-bastion"
zvsi_name="$IC_INFRA_NAME-compute"
dns_name="$IC_INFRA_NAME-$PROW_JOB_ID"
dns_zone="$BASE_DOMAIN"

# Login to the IBM Cloud
echo "Logging into IBM Cloud by targetting the $IC_REGION region"
ibmcloud login --apikey $IC_APIKEY
ibmcloud target -r $IC_REGION -g $rg_name

# Deleting the DNS Service
echo "Installing the JSON Querier(jq)."
yum install jq -y
echo "Triggering the $dns_name DNS instance deletion in the resource group $rg_name."
dns_zone_id=$(ibmcloud dns zones -i $dns_name | grep $dns_zone | awk 'print $1}')
network_id=$(ibmcloud is vpc $vpc_name --output JSON | jq '.id')
network_deletion=$(ibmcloud dns permitted-network-remove $dns_zone_id $network_id -i $dns_name -f | grep OK | wc -l)
if [ $network_deletion == "1" ]; then
  echo "Successfully deleted the permitted network $vpc_name in the $dns_zone DNS Zone."
else 
  echo "Error: Failed to delete the $vpc_name permitted network in the $dns_zone DNS Zone."
  exit 1
fi
dns_deletion=$(ibmcloud dns instance-delete $dns_name -f)
if [ $dns_deletion == "OK" ]; then
  echo "Successfully deleted the DNS service instance $dns_name from the resource group $rg_name."
else 
  echo "Error: Failed to delete the DNS service instance $dns_name from the resource group $rg_name."
  exit 1
fi

# Deleting the VSIs
echo "Triggering the $zvsi_name and $rhel_vsi_name instances deletion in the $vpc_name VPC."
vsi_delete_status=$(ibmcloud is instance-delete $zvsi_name $rhel_vsi_name --output JSON -f | jq '.[]|.result')
if [ echo "${vsi_delete_status[@]}" | grep -q "false" ]; then
  echo "$zvsi_name and $rhel_vsi_name instances deletion status are $vsi_delete_status respectively."
  exit 1
else 
  echo "Successfully deleted the $zvsi_name and $rhel_vsi_name instances in the $vpc_name VPC."
fi

# Deleting the subnet
echo "Triggering the $sn_name subnet deletion in the $vpc_name VPC."
sn_delete_status=$(ibmcloud is subnet-delete $sn_name --vpc $vpc_name --output JSON -f | jq '.[]|.result')
if [ $sn_delete_status == "true" ]; then
  echo "Successfully deleted the subnet $sn_name in the $vpc_name VPC."
else 
  echo "Error: Failed to delete the $sn_name subnet in the $vpc_name VPC."
  exit 1
fi

# Deleting the VPC
echo "Triggering the $vpc_name VPC deletion in the $rg_name resource group."
vpc_delete_status=$(ibmcloud is vpc-delete $vpc_name --output JSON -f | jq '.[]|.result')
if [ $vpc_delete_status == "true" ]; then
  echo "Successfully deleted the VPC $vpc_name in the $rg_name resource group."
else 
  echo "Error: Failed to delete the $vpc_name VPC in the $rg_name resource group."
  exit 1
fi

# Deleting the SSH key
echo "Triggering the $ssh_key_name SSH key deletion in the resource group $rg_name resource group."
ssh_key_delete_status=$(ibmcloud is key-delete $ssh_key_name --output JSON -f | jq '.[]|.result')
if [ $ssh_key_delete_status == "true" ]; then
  echo "Successfully deleted the SSH key $ssh_key_name in the $rg_name resource group."
else 
  echo "Error: Failed to delete the $ssh_key_name SSH key in the $rg_name resource group."
  exit 1
fi

# Deleting the resource group
echo "Triggering the $rg_name resource group deletion in the $IC_REGION region."
rg_delete_status=$(ibmcloud resource group-delete $rg_name -f | grep OK | wc -l)
if [ $rg_delete_status == "1" ]; then
  echo "Successfully deleted the resource group $rg_name in the $IC_REGION region."
else 
  echo "Error: Failed to delete the $rg_name resource group in the $IC_REGION region."
  exit 1
fi