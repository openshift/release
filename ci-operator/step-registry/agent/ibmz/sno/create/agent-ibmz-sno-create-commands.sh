#!/bin/bash

set -x

# Session variables
infra_name="$CLUSTER_NAME-$(echo -n $PROW_JOB_ID|cut -c-8)"
plugins_list=("vpc-infrastructure" "cloud-dns-services")
IC_API_KEY=$(cat "${AGENT_IBMZ_CREDENTIALS}/ibmcloud-apikey")
export IC_API_KEY
httpd_vsi_ip=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-ip")
export httpd_vsi_ip
httpd_vsi_pub_key="${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-pub-key"
export httpd_vsi_pub_key
httpd_vsi_key="${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-key"
export httpd_vsi_key
pull_secret="${AGENT_IBMZ_CREDENTIALS}/abi-pull-secret"
export pull_secret

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
set -e
echo "Logging into IBM Cloud by targetting the $IC_REGION region"
ibmcloud config --check-version=false                               # To avoid manual prompt for updating CLI version
ibmcloud login --apikey $IC_API_KEY -r $IC_REGION
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
vpc_crn=$(ibmcloud is vpc $infra_name-vpc | awk '/CRN/{print $2}')

# Create subnet
set -e
echo "Creating a subnet in the VPC $infra_name-vpc"
ibmcloud is subnet-create $infra_name-sn $infra_name-vpc --ipv4-address-count 16 --zone "$IC_REGION-1" --resource-group-name $infra_name-rg
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
echo "Triggering the $infra_name-sno zVSI creation on IBM Cloud in the VPC $infra_name-vpc"
ibmcloud is instance-create $infra_name-sno $infra_name-vpc $IC_REGION-1 $ZVSI_PROFILE $infra_name-sn --image $ZVSI_IMAGE --keys hcp-prow-ci-dnd-key --resource-group-name $infra_name-rg
sleep 60
set +e
zvsi_state=$(ibmcloud is instance $infra_name-sno | awk '/Status/{print $2}')
if [ "$zvsi_state" != "running" ]; then
  echo "Error: Instance $infra_name-sno is not created properly in the $infra_name-vpc VPC."
  exit 1
else 
  echo "Instance $infra_name-sno is created successfully in the $infra_name-vpc VPC."
  zvsi_rip=$(ibmcloud is instance $infra_name-sno --output json | jq -r '.primary_network_interface.primary_ip.address')
fi
sg_name=$(ibmcloud is instance $infra_name-sno --output JSON | jq -r '.network_interfaces|.[].security_groups|.[].name')
echo "Adding an inbound rule in the $infra_name-sno instance security group for ssh and scp."
ibmcloud is sg-rulec $sg_name inbound tcp --port-min 22 --port-max 22
if [ $? -eq 0 ]; then
    echo "Successfully added the inbound rule."
else
    echo "Failure while adding the inbound rule to the $infra_name-sno instance security group."
    exit 1
fi  
nic_name=$(ibmcloud is in-nics $infra_name-sno -q | grep -v ID | awk '{print $2}')
echo "Creating a Floating IP for zVSI"
zvsi_fip=$(ibmcloud is ipc $infra_name-sno-ip --zone $IC_REGION-1 --resource-group-name $infra_name-rg | awk '/Address/{print $2}')
echo "Assigning the Floating IP for zVSI"
zvsi_fip_status=$(ibmcloud is in-nic-ipc $infra_name-sno $nic_name $infra_name-sno-ip | awk '/Status/{print $2}')
if [ "$zvsi_fip_status" != "available" ]; then
  echo "Error: Floating IP $infra_name-sno-ip is not assigned to the $infra_name-sno instance."
  exit 1
else 
  echo "Floating IP $infra_name-sno-ip is successfully assigned to the $infra_name-sno instance."
fi

# Creating DNS service
echo "Triggering the DNS Service creation on IBM Cloud in the resource group $infra_name-rg"
dns_state=$(ibmcloud dns instance-create $infra_name-dns standard-dns -g $infra_name-rg --output JSON | jq -r '.state')
if [ "$dns_state" == "active" ]; then
  echo "$infra_name-dns DNS instance is created successfully and in active state."
else 
  echo "DNS instance $infra_name-dns is not in the active state."
  exit 1
fi

echo "Creating the DNS zone $BASEDOMAIN in the instance $infra_name-dns."
dns_zone_id=$(ibmcloud dns zone-create "$BASEDOMAIN" -i $infra_name-dns --output JSON | jq -r '.id')
if [ -z $dns_zone_id ]; then
  echo "DNS zone $BASEDOMAIN is not created properly as it is not possesing any ID."
  exit 1
else 
  echo "DNS zone $BASEDOMAIN is created successfully in the instance $infra_name-dns."
fi

echo "Adding VPC network $infra_name-vpc to the DNS zone $BASEDOMAIN"
dns_network_state=$(ibmcloud dns permitted-network-add $dns_zone_id --type vpc --vpc-crn $vpc_crn -i $infra_name-dns --output JSON | jq -r '.state')
if [ "$dns_network_state" != "ACTIVE" ]; then
  echo "VPC network $infra_name-vpc which is added to the DNS zone $BASEDOMAIN is not in ACTIVE state."
  exit 1
else 
  echo "VPC network $infra_name-vpc is successfully added to the DNS zone $BASEDOMAIN."
  echo "DNS zone $BASEDOMAIN is in the ACTIVE state."
fi

echo "Adding A records in the DNS zone $BASEDOMAIN to resolve the api URLs of SNO cluster to the node IP."
ibmcloud dns resource-record-create $dns_zone_id --type A --name "api.$CLUSTER_NAME" --ipv4 $zvsi_rip -i $infra_name-dns
ibmcloud dns resource-record-create $dns_zone_id --type A --name "api-int.$CLUSTER_NAME" --ipv4 $zvsi_rip -i $infra_name-dns
ibmcloud dns resource-record-create $dns_zone_id --type A --name "*.apps.$CLUSTER_NAME" --ipv4 $zvsi_rip -i $infra_name-dns
if [ $? -eq 0 ]; then
  echo "Successfully added the A record of zVSI compute node IP to resolve the hosted cluster apis."
else 
  echo "A record addition is not successful."
  exit 1
fi

# Fetch the zVSI mac address
set -e
echo "Fetching the mac address of zVSI $zvsi_fip"
ssh_options=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=60' -i "$httpd_vsi_key")
zvsi_mac=$(ssh "${ssh_options[@]}" core@$zvsi_fip "ip link show | awk '/ether/ {print \$2}'")

# Building openshift-install binary
echo "Checking the openshift-install version"
openshift-install version

echo "Creating agent-config and install-config files"
mkdir $HOME/$CLUSTER_NAME
# Agent Config 
cat <<EOF > $HOME/$CLUSTER_NAME/agent-config.yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: $CLUSTER_NAME
rendezvousIP: $zvsi_rip
hosts:
  - hostname: master
    role: master
    interfaces:
      - name: eth0
        macAddress: $zvsi_mac
    networkConfig:
      interfaces:
        - name: eth0
          type: ethernet
          state: up
          mac-address: $zvsi_mac
          ipv4:
            enabled: true
            address:
              - ip: $zvsi_rip
                prefix-length: 24
            dhcp: true
EOF
# Install Config
cat <<EOF > $HOME/$CLUSTER_NAME/install-config.yaml
apiVersion: v1
baseDomain: $BASEDOMAIN
controlPlane:
  architecture: s390x
  hyperthreading: Enabled
  name: master
  replicas: 1
compute:
- architecture: s390x
  hyperthreading: Enabled
  name: worker
  replicas: 0
metadata:
  name: $CLUSTER_NAME
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.244.0.0/24
  networkType: OVNKubernetes 
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
pullSecret: >
  @$pull_secret
sshKey: >
  @$httpd_vsi_pub_key
EOF
echo "Generating pxe-boot artifacts for SNO cluster"
openshift-install create pxe-files --dir $HOME/$CLUSTER_NAME/ --log-level debug

# Generating script for agent boot execution on zVSI
echo "Uploading the pxe-boot artifacts to HTTPD server"
scp -r "${ssh_options[@]}" $HOME/$CLUSTER_NAME/boot-artifacts/ root@$httpd_vsi_ip:/var/www/html/
ssh "${ssh_options[@]}" root@$httpd_vsi_ip "mv /var/www/html/boot-artifacts/* /var/www/html/; chmod 644 /var/www/html/*; rm -rf /var/www/html/boot-artifacts/"
echo "Downloading the setup script for pxeboot of SNO"
curl -k -L --output $HOME/setup_pxeboot.sh "http://$httpd_vsi_ip:80/setup_pxeboot.sh"
initrd_url="http://$httpd_vsi_ip:80/agent.s390x-initrd.img"
kernel_url="http://$httpd_vsi_ip:80/agent.s390x-kernel.img"
sed -i "s|INITRD_URL|${initrd_url}|" $HOME/setup_pxeboot.sh 
sed -i "s|KERNEL_URL|${kernel_url}|" $HOME/setup_pxeboot.sh 
sed -i "s|HTTPD_VSI_IP|${httpd_vsi_ip}|" $HOME/setup_pxeboot.sh 
sed -i "s|rootfs.img|agent.s390x-rootfs.img|" $HOME/setup_pxeboot.sh 
chmod 700 $HOME/setup_pxeboot.sh

# Booting up zVSI as SNO cluster
echo "Transferring the setup script to zVSI $zvsi_fip"
scp "${ssh_options[@]}" $HOME/setup_pxeboot.sh core@$zvsi_fip:/var/home/core/setup_pxeboot.sh
echo "Triggering the script in the zVSI $zvsi_fip"
ssh "${ssh_options[@]}" core@$zvsi_fip "/var/home/core/setup_pxeboot.sh" &
sleep 60
echo "Successfully booted the zVSI $zvsi_fip with the setup script"

# Deleting the resources in the pod
rm -f $HOME/setup_pxeboot.sh

# Wait for bootstrapping to complete
echo "$(date) Waiting for the bootstrapping to complete"
openshift-install wait-for bootstrap-complete --dir $HOME/$CLUSTER_NAME/

# Wait for installation to complete
echo "$(date) Waiting for the installation to complete"
openshift-install wait-for install-complete --dir $HOME/$CLUSTER_NAME/
cp $HOME/$CLUSTER_NAME/auth/kubeconfig ${SHARED_DIR}/$CLUSTER_NAME-kubeconfig
