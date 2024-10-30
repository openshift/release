#!/bin/bash

set -x

# Session variables
job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
infra_name="odh-ci-$job_id"
plugins_list=("vpc-infrastructure" "cloud-dns-services")
httpd_vsi_ip=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-ip")
export httpd_vsi_ip

# Installing CLI tools
set -e
echo "Installing required CLI tools"
mkdir /tmp/bin
echo "Installing jq...."
curl -L https://github.com/stedolan/jq/releases/download/${JQ_VERSION}/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
PATH=$PATH:/tmp/bin
export PATH
echo "Installing nmstatectl...."
wget -q -O $HOME/nmstatectl-linux-x64.zip https://github.com/nmstate/nmstate/releases/download/${NMSTATE_VERSION}/nmstatectl-linux-x64.zip
unzip $HOME/nmstatectl-linux-x64.zip -d /tmp/bin/ && chmod +x /tmp/bin/nmstatectl
which nmstatectl
if [ $? -eq 0 ]; then
  echo "nmstatectl is installed successfully."
else
  echo "nmstatectl installation is not successful."
  exit 1
fi

# Installing IBM cloud CLI
echo "Installing ibmcloud CLI ...."
mkdir /tmp/ibm_cloud_cli
curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/${IC_CLI_VERSION}/IBM_Cloud_CLI_${IC_CLI_VERSION}_amd64.tar.gz
tar -xzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
which ibmcloud
if [ $? -eq 0 ]; then
  echo "ibmcloud is installed successfully."
else
  echo "ibmcloud installation is not successful."
  exit 1
fi

# Login to the IBM Cloud
echo "Logging into IBM Cloud by targetting the $IC_REGION region"
ibmcloud config --check-version=false                               # To avoid manual prompt for updating CLI version
ibmcloud login --apikey @${AGENT_IBMZ_CREDENTIALS}/ibmcloud-apikey -r $IC_REGION -q > /dev/null
set +e
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

# Create resource group
set -e
echo "Creating a resource group in the region $IC_REGION"
ibmcloud resource group-create $infra_name-rg
rg_state=$(ibmcloud resource group $infra_name-rg | awk '/State/{print $2}')
set +e
if [ "$rg_state" != "ACTIVE" ]; then
  echo "Error: Resource Group $infra_name-rg is not created properly."
  exit 1
else 
  echo "Resource Group $infra_name-rg is created successfully and is in active state in the $IC_REGION region."
fi

# Create VPC
set -e
echo "Creating a VPC in the resource group $infra_name-rg"
ibmcloud is vpc-create $infra_name-vpc --resource-group-name $infra_name-rg
set +e
vpc_status=$(ibmcloud is vpc $infra_name-vpc | awk '/Status/{print $2}')
if [ "$vpc_status" != "available" ]; then
  echo "Error: VPC $infra_name-vpc is not created properly."
  exit 1
else 
  echo "VPC $infra_name-vpc is created successfully in the $IC_REGION region."
fi

# Create subnet
set -e
echo "Creating a subnet in the VPC $infra_name-vpc"
ibmcloud is subnet-create $infra_name-sn $infra_name-vpc --ipv4-address-count 256 --zone "$IC_REGION-2" --resource-group-name $infra_name-rg
sn_status=$(ibmcloud is subnet $infra_name-sn | awk '/Status/{print $2}')
set +e
if [ "$sn_status" != "available" ]; then
  echo "Error: Subnet $infra_name-sn is not created properly in the VPC $infra_name-vpc."
  exit 1
else 
  echo "Subnet $infra_name-sn is created successfully in the $infra_name-vpc VPC."
fi

# Create zVSI compute nodes
set -e
zvsi_rip=""
echo "Triggering the $infra_name-vm zVSI creation on IBM Cloud in the VPC $infra_name-vpc"
vol_json=$(jq -n -c --arg volume "$infra_name-vm-volume" '{"name": $volume, "volume": {"name": $volume, "capacity": 100, "profile": {"name": "general-purpose"}}}')
ibmcloud is instance-create $infra_name-vm $infra_name-vpc $IC_REGION-2 $ZVSI_PROFILE $infra_name-sn --image $ZVSI_IMAGE --keys hcp-prow-ci-dnd-key --resource-group-name $infra_name-rg --boot-volume $vol_json
sleep 60
set +e
zvsi_state=$(ibmcloud is instance $infra_name-vm | awk '/Status/{print $2}')
if [ "$zvsi_state" != "running" ]; then
  echo "Error: Instance $infra_name-vm is not created properly in the $infra_name-vpc VPC."
  exit 1
else 
  echo "Instance $infra_name-vm is created successfully in the $infra_name-vpc VPC."
fi
sg_name=$(ibmcloud is instance $infra_name-vm --output JSON | jq -r '.network_interfaces|.[].security_groups|.[].name')
echo "Adding an inbound rule in the $infra_name-vm instance security group for ssh and scp."
ibmcloud is sg-rulec $sg_name inbound tcp --port-min 22 --port-max 22
if [ $? -eq 0 ]; then
    echo "Successfully added the inbound rule."
else
    echo "Failure while adding the inbound rule to the $infra_name-vm instance security group."
    exit 1
fi  
echo "Getting the Virtual Network Interface ID for zVSI"
vni_id=$(ibmcloud is instance $infra_name-vm | awk '/Primary/{print $7}')
echo "Creating a Floating IP for zVSI"
zvsi_fip=$(ibmcloud is floating-ip-reserve $infra_name-vm-ip --nic $vni_id | awk '/Address/{print $2}')
if [ -z "$zvsi_fip" ]; then
  echo "Error: Floating IP assignment is failed to the zVSI."
  exit 1
else
  echo "Floating IP is assigned to the zVSI : $zvsi_fip"
fi

# storing fip in shared dir to use in later steps
echo zvsi_fip >> ${SHARED_DIR}/zvsi_fip

