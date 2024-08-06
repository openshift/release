#!/bin/bash

set -x

# Session variables
job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
infra_name="$CLUSTER_NAME-$job_id"
plugins_list=("vpc-infrastructure" "cloud-dns-services")
httpd_vsi_ip=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-ip")
export httpd_vsi_ip

# Installing CLI tools
set -e
echo "Installing required CLI tools"
mkdir /tmp/bin
echo "Installing jq...."
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
PATH=$PATH:/tmp/bin
export PATH
echo "Installing nmstatectl...."
wget -q -O $HOME/nmstatectl-linux-x64.zip https://github.com/nmstate/nmstate/releases/download/v2.2.23/nmstatectl-linux-x64.zip
unzip $HOME/nmstatectl-linux-x64.zip -d /tmp/bin/ && chmod +x /tmp/bin/nmstatectl
which nmstatectl
if [ $? -eq 0 ]; then
  echo "nmstatectl is installed successfully."
else
  echo "nmstatectl installation is not successful."
  exit 1
fi
echo "Installing oc...."
wget -q -O $HOME/openshift-client-linux.tar.gz https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux.tar.gz
tar -xzf $HOME/openshift-client-linux.tar.gz -C /tmp/bin
which oc
if [ $? -eq 0 ]; then
  echo "oc is installed successfully."
else
  echo "oc installation is not successful."
  exit 1
fi
echo "Installing ibmcloud...."
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
vpc_crn=$(ibmcloud is vpc $infra_name-vpc | awk '/CRN/{print $2}')

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
sn_cidr=$(ibmcloud is subnet $infra_name-sn --vpc $infra_name-vpc --output JSON | jq -r '.ipv4_cidr_block')

# Create zVSI compute nodes
set -e
zvsi_rip=""
echo "Triggering the $infra_name-sno zVSI creation on IBM Cloud in the VPC $infra_name-vpc"
vol_json=$(jq -n -c --arg volume "$infra_name-sno-volume" '{"name": $volume, "volume": {"name": $volume, "capacity": 100, "profile": {"name": "general-purpose"}}}')
ibmcloud is instance-create $infra_name-sno $infra_name-vpc $IC_REGION-2 $ZVSI_PROFILE $infra_name-sn --image $ZVSI_IMAGE --keys hcp-prow-ci-dnd-key --resource-group-name $infra_name-rg --boot-volume $vol_json
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
echo "Getting the Virtual Network Interface ID for zVSI"
vni_id=$(ibmcloud is instance $infra_name-sno | awk '/Primary/{print $7}')
echo "Creating a Floating IP for zVSI"
zvsi_fip=$(ibmcloud is floating-ip-reserve $infra_name-sno-ip --nic $vni_id | awk '/Address/{print $2}')
if [ -z "$zvsi_fip" ]; then
  echo "Error: Floating IP assignment is failed to the zVSI."
  exit 1
else
  echo "Floating IP is assigned to the zVSI : $zvsi_fip"
fi

# Create a bastion node in the same VPC for monitoring
set -e
echo "Triggering the $infra_name-bastion VSI creation on IBM Cloud in the VPC $infra_name-vpc"
ibmcloud is instance-create $infra_name-bastion $infra_name-vpc $IC_REGION-2 bx2-2x8 $infra_name-sn --image ibm-redhat-9-2-minimal-amd64-2 --keys hcp-prow-ci-dnd-key --resource-group-name $infra_name-rg
sleep 60
set +e
bvsi_state=$(ibmcloud is instance $infra_name-bastion | awk '/Status/{print $2}')
if [ "$bvsi_state" != "running" ]; then
  echo "Error: Instance $infra_name-bastion is not created properly in the $infra_name-vpc VPC."
  exit 1
else 
  echo "Instance $infra_name-bastion is created successfully in the $infra_name-vpc VPC."
fi
bsg_name=$(ibmcloud is instance $infra_name-bastion --output JSON | jq -r '.network_interfaces|.[].security_groups|.[].name')
echo "Adding an inbound rule in the $infra_name-bastion instance security group for ssh and scp."
ibmcloud is sg-rulec $bsg_name inbound tcp --port-min 22 --port-max 22
if [ $? -eq 0 ]; then
    echo "Successfully added the inbound rule."
else
    echo "Failure while adding the inbound rule to the $infra_name-bastion instance security group."
    exit 1
fi  
echo "Getting the Virtual Network Interface ID for bastion VSI"
bvni_id=$(ibmcloud is instance $infra_name-bastion | awk '/Primary/{print $7}')
echo "Creating a Floating IP for bastion VSI"
bvsi_fip=$(ibmcloud is floating-ip-reserve $infra_name-bastion-ip --nic $bvni_id | awk '/Address/{print $2}')
if [ -z "$bvsi_fip" ]; then
  echo "Error: Floating IP assignment is failed to the bastion VSI."
  exit 1
else
  echo "Floating IP is assigned to the bastion VSI : $bvsi_fip"
fi
echo $bvsi_fip >> ${SHARED_DIR}/bastion-vsi-ip  # Storing to access in further steps 

# Creating DNS service
echo "Triggering the DNS Service creation on IBM Cloud in the resource group $infra_name-rg"
ibmcloud dns instance-create $infra_name-dns standard-dns -g $infra_name-rg
sleep 30
dns_state=$(ibmcloud dns instance $infra_name-dns --output JSON | jq -r '.state')
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
ssh_key_string=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-key")
export ssh_key_string
tmp_ssh_key="/tmp/httpd-vsi-key"
envsubst <<"EOF" >${tmp_ssh_key}
-----BEGIN OPENSSH PRIVATE KEY-----
${ssh_key_string}

-----END OPENSSH PRIVATE KEY-----
EOF
chmod 0600 ${tmp_ssh_key}
ssh_options=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=60' -i "$tmp_ssh_key")
zvsi_mac=$(ssh "${ssh_options[@]}" root@$zvsi_fip "ip link show | awk '/ether/ {print \$2}'")

echo "Creating agent-config and install-config files"
mkdir $HOME/$CLUSTER_NAME
# Agent Config 
cat >> $HOME/$CLUSTER_NAME/agent-config.yaml << EOF
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
cat >> $HOME/$CLUSTER_NAME/install-config.yaml << EOF
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
  - cidr: $sn_cidr
  networkType: OVNKubernetes 
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
EOF
# Adding pull-secret and ssh key
cat "${AGENT_IBMZ_CREDENTIALS}/abi-pull-secret" | jq -c > "$HOME/abi-pull-secret-compact" #minimising the json content to embed in the config
cat >> "$HOME/$CLUSTER_NAME/install-config.yaml" << EOF
pullSecret: >
  $(<"$HOME/abi-pull-secret-compact")
sshKey: |
  $(<"${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-pub-key")
EOF

# Extracting the installer binary
echo "Extracting the openshift-install binary"
oc adm release extract -a $HOME/abi-pull-secret-compact --command openshift-install $OCP_RELEASE_IMAGE --to=$HOME/$CLUSTER_NAME/

# Generate PXE artifacts
echo "Generating pxe-boot artifacts for SNO cluster"
$HOME/$CLUSTER_NAME/openshift-install agent create pxe-files --dir $HOME/$CLUSTER_NAME/ --log-level debug
cp -r $HOME/$CLUSTER_NAME/boot-artifacts/ $HOME/$CLUSTER_NAME/boot-artifacts-$job_id/ 

# Generating script for agent boot execution on zVSI
echo "Uploading the pxe-boot artifacts to HTTPD server"
scp -r "${ssh_options[@]}" $HOME/$CLUSTER_NAME/boot-artifacts-$job_id/ root@$httpd_vsi_ip:/var/www/html/
ssh "${ssh_options[@]}" root@$httpd_vsi_ip "chmod -R 755 /var/www/html/boot-artifacts-$job_id/"
echo "Downloading the setup script for pxeboot of SNO"
curl -k -L --output $HOME/trigger_pxeboot.sh "http://$httpd_vsi_ip:80/trigger_pxeboot.sh"
initrd_url="http://$httpd_vsi_ip:80/boot-artifacts-$job_id/agent.s390x-initrd.img"
kernel_url="http://$httpd_vsi_ip:80/boot-artifacts-$job_id/agent.s390x-kernel.img"
rootfs_url="http://$httpd_vsi_ip:80/boot-artifacts-$job_id/agent.s390x-rootfs.img"
sed -i "s|INITRD_URL|${initrd_url}|" $HOME/trigger_pxeboot.sh 
sed -i "s|KERNEL_URL|${kernel_url}|" $HOME/trigger_pxeboot.sh 
sed -i "s|ROOTFS_URL|${rootfs_url}|" $HOME/trigger_pxeboot.sh 
chmod 700 $HOME/trigger_pxeboot.sh

# Booting up zVSI as SNO cluster
echo "Transferring the setup script to zVSI $zvsi_fip"
scp "${ssh_options[@]}" $HOME/trigger_pxeboot.sh root@$zvsi_fip:/root/trigger_pxeboot.sh
echo "Triggering the script in the zVSI $zvsi_fip"
ssh "${ssh_options[@]}" root@$zvsi_fip "/root/trigger_pxeboot.sh" &
sleep 60
echo "Successfully booted the zVSI $zvsi_fip with the setup script"

# Deleting the additional resources in the pod
rm -rf $HOME/trigger_pxeboot.sh $HOME/$CLUSTER_NAME/boot-artifacts-$job_id/

# Wait for installation to complete --> monitoring in bastion node
echo "Uploading the cluster artifacts directory to bastion node for monitoring"
cp /tmp/bin/oc $HOME/$CLUSTER_NAME/
scp -r "${ssh_options[@]}" $HOME/$CLUSTER_NAME/ root@$bvsi_fip:/root/
echo "$(date) Waiting for the installation to complete"
ssh "${ssh_options[@]}" root@$bvsi_fip "/root/$CLUSTER_NAME/openshift-install wait-for install-complete --dir /root/$CLUSTER_NAME/ --log-level debug 2>&1 | grep --line-buffered -v password &"

# Password for the cluster gets leaked in the installer logs and hence removing them.
sed -i 's/password: .*/password: REDACTED"/g' $HOME/$CLUSTER_NAME/.openshift_install.log