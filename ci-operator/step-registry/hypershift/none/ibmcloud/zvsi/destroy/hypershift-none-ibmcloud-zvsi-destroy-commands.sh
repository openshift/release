#!/bin/bash

set -exuo pipefail

infra_name="hcp-s390x-$(echo -n $PROW_JOB_ID|cut -c-8)"
rg_name="$infra_name-rg"
ssh_key_name="$infra_name-key"
vpc_name="$infra_name-vpc"
sn_name="$infra_name-sn"
rhel_vsi_name="$infra_name-bastion"
zvsi_name="$infra_name-compute"
dns_name="$infra_name-dns"
dns_zone="$BASE_DOMAIN"
cos_si_name="$infra_name-si"
zvsi_image="rhcos-$ZVSI_IMAGE_VERSION-ibmcloud.s390x.qcow2"
zvsi_image_name=${zvsi_image//[._]/-}

# Login to the IBM Cloud
echo "Logging into IBM Cloud in the $IC_REGION region and $rg_name resource group."
ibmcloud login --apikey $IC_APIKEY -r $IC_REGION -g $rg_name
echo "Installing the JSON Querier(jq)."
yum install jq -y

# Deleting the DNS Service
echo "Triggering the $dns_name DNS instance deletion in the resource group $rg_name."
dns_zone_id=$(ibmcloud dns zones -i $dns_name | grep $dns_zone | awk '{print $1}')
network_id=$(ibmcloud is vpc $vpc_name --output JSON | jq -r '.id')
ibmcloud dns permitted-network-remove $dns_zone_id $network_id -i $dns_name -f 
ibmcloud dns instance-delete $dns_name -f
echo "Successfully deleted the DNS instance $dns_name from the resource group $rg_name."
set +e

# Deleting the VSIs
echo "Triggering the $zvsi_name and $rhel_vsi_name instances deletion in the $vpc_name VPC."
vsi_delete_status=$(ibmcloud is instance-delete $zvsi_name $rhel_vsi_name --output JSON -f | jq -r '.[]|.result')
if [ echo $vsi_delete_status | grep -q "false" ]; then
  echo "$zvsi_name and $rhel_vsi_name instances deletion status are $vsi_delete_status respectively."
  exit 1
else 
  echo "Successfully deleted the $zvsi_name and $rhel_vsi_name instances in the $vpc_name VPC."
fi

# Deleting the custom image
echo "Triggering the $zvsi_image_name custom image deletion in the $rg_name resource group."
image_delete_status=$(ibmcloud is image-delete $zvsi_image_name -f --output JSON | jq -r '.[]|.result')
if [ $image_delete_status == "true" ]; then
  echo "Successfully deleted the custom image $zvsi_image_name in the $rg_name resource group."
else 
  echo "Error: Failed to delete the custom image $zvsi_image_name in the $rg_name resource group."
  exit 1
fi

# Deleting the COS service-instance and it's resources
set -e
echo "Triggering the $cos_si_name service instance deletion in the $rg_name resource group."
ibmcloud resource service-instance-delete $cos_si_name  -g $rg_name -f --recursive
echo "Successfully deleted the COS Service Instance $cos_si_name in the $rg_name resource group." 
set +e

# Deleting the Floating IPs
echo "Triggering the $zvsi_name-ip and $rhel_vsi_name-ip Floating IPs in the $rg_name resource group."
fip_delete_status=$(ibmcloud is ipd $zvsi_name-ip $rhel_vsi_name-ip --output JSON -f | jq -r '.[]|.result')
if [ echo $fip_delete_status | grep -q "false" ]; then
  echo "$zvsi_name-ip and $rhel_vsi_name-ip floating ips deletion status are $fip_delete_status respectively."
  exit 1
else 
  echo "Successfully deleted the $zvsi_name-ip and $rhel_vsi_name-ip floating ips in the $rg_name resource group."
fi

# Deleting the subnet
echo "Triggering the $sn_name subnet deletion in the $vpc_name VPC."
sn_delete_status=$(ibmcloud is subnet-delete $sn_name --vpc $vpc_name --output JSON -f | jq -r '.[]|.result')
if [ $sn_delete_status == "true" ]; then
  echo "Successfully deleted the subnet $sn_name in the $vpc_name VPC."
else 
  echo "Error: Failed to delete the $sn_name subnet in the $vpc_name VPC."
  exit 1
fi

# Deleting the VPC
echo "Triggering the $vpc_name VPC deletion in the $rg_name resource group."
vpc_delete_status=$(ibmcloud is vpc-delete $vpc_name --output JSON -f | jq -r '.[]|.result')
if [ $vpc_delete_status == "true" ]; then
  echo "Successfully deleted the VPC $vpc_name in the $rg_name resource group."
else 
  echo "Error: Failed to delete the $vpc_name VPC in the $rg_name resource group."
  exit 1
fi

# Deleting the SSH key
echo "Triggering the $ssh_key_name SSH key deletion in the resource group $rg_name resource group."
ssh_key_delete_status=$(ibmcloud is key-delete $ssh_key_name --output JSON -f | jq -r '.[]|.result')
if [ $ssh_key_delete_status == "true" ]; then
  echo "Successfully deleted the SSH key $ssh_key_name in the $rg_name resource group."
else 
  echo "Error: Failed to delete the $ssh_key_name SSH key in the $rg_name resource group."
  exit 1
fi

# Deleting the resource group
set -e
echo "Triggering the $rg_name resource group deletion in the $IC_REGION region."
ibmcloud resource group-delete $rg_name -f
echo "Successfully completed the destruction of all the resources that are created during the CI."
set +e