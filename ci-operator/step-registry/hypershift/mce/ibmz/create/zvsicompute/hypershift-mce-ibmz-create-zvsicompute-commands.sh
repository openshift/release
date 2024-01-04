#!/bin/bash

set -x

# Session variables
infra_name="$HC_NAME-$(echo -n $PROW_JOB_ID|cut -c-8)"
plugins_list=("vpc-infrastructure" "cloud-dns-services")
hcp_ns=$HC_NS-$HC_NAME
export hcp_ns
IC_API_KEY=$(cat "${AGENT_IBMZ_CREDENTIALS}/ibmcloud-apikey")
export IC_API_KEY
httpd_vsi_pub_key="${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-pub-key"
export httpd_vsi_pub_key
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

# Create SSH key
set -e
echo "Creating an SSH key in the resource group $infra_name-rg"
ibmcloud is key-create $infra_name-key @$httpd_vsi_pub_key --resource-group-name $infra_name-rg
ibmcloud is keys --resource-group-name $infra_name-rg | grep -i $infra_name-key
set +e

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
zvsi_rip_list=()
zvsi_fip_list=()
for ((i = 0; i < $HYPERSHIFT_NODE_COUNT ; i++)); do
  echo "Triggering the $infra_name-compute-$i zVSI creation on IBM Cloud in the VPC $infra_name-vpc"
  vol_json=$(jq -n -c --arg volume "$infra_name-compute-$i-volume" '{"name": $volume, "volume": {"name": $volume, "capacity": 250, "profile": {"name": "general-purpose"}}}')
  ibmcloud is instance-create $infra_name-compute-$i $infra_name-vpc $IC_REGION-1 $ZVSI_PROFILE $infra_name-sn --image $ZVSI_IMAGE --keys $infra_name-key --resource-group-name $infra_name-rg --boot-volume $vol_json
  set +e
  sleep 60
  zvsi_state=$(ibmcloud is instance $infra_name-compute-$i | awk '/Status/{print $2}')
  if [ "$zvsi_state" != "running" ]; then
    echo "Error: Instance $infra_name-compute-$i is not created properly in the $infra_name-vpc VPC."
    exit 1
  else 
    echo "Instance $infra_name-compute-$i is created successfully in the $infra_name-vpc VPC."
    zvsi_rip=$(ibmcloud is instance $infra_name-compute-$i --output json | jq -r '.primary_network_interface.primary_ip.address')
    zvsi_rip_list+=("$zvsi_rip")
  fi
  sg_name=$(ibmcloud is instance $infra_name-compute-$i --output JSON | jq -r '.network_interfaces|.[].security_groups|.[].name')
  echo "Adding an inbound rule in the $infra_name-compute-$i instance security group for ssh and scp."
  ibmcloud is sg-rulec $sg_name inbound tcp --port-min 22 --port-max 22
  if [ $? -eq 0 ]; then
      echo "Successfully added the inbound rule."
  else
      echo "Failure while adding the inbound rule to the $infra_name-compute-$i instance security group."
      exit 1
  fi  
  nic_name=$(ibmcloud is in-nics $infra_name-compute-$i -q | grep -v ID | awk '{print $2}')
  echo "Creating a Floating IP for zVSI"
  zvsi_fip=$(ibmcloud is ipc $infra_name-compute-$i-ip --zone $IC_REGION-1 --resource-group-name $infra_name-rg | awk '/Address/{print $2}')
  echo "Assigning the Floating IP for zVSI"
  zvsi_fip_status=$(ibmcloud is in-nic-ipc $infra_name-compute-$i $nic_name $infra_name-compute-$i-ip | awk '/Status/{print $2}')
  if [ "$zvsi_fip_status" != "available" ]; then
    echo "Error: Floating IP $infra_name-compute-ip is not assigned to the $infra_name-compute instance."
    exit 1
  else 
    echo "Floating IP $infra_name-compute-ip is successfully assigned to the $infra_name-compute instance."
    zvsi_fip_list+=("$zvsi_fip")
  fi
done

# Creating DNS service
echo "Triggering the DNS Service creation on IBM Cloud in the resource group $infra_name-rg"
dns_state=$(ibmcloud dns instance-create $infra_name-dns standard-dns -g $infra_name-rg --output JSON | jq -r '.state')
if [ "$dns_state" == "active" ]; then
  echo "$infra_name-dns DNS instance is created successfully and in active state."
else 
  echo "DNS instance $infra_name-dns is not in the active state."
  exit 1
fi

echo "Creating the DNS zone $HC_NAME.$HYPERSHIFT_BASEDOMAIN in the instance $infra_name-dns."
dns_zone_id=$(ibmcloud dns zone-create "$HC_NAME.$HYPERSHIFT_BASEDOMAIN" -i $infra_name-dns --output JSON | jq -r '.id')
if [ -z $dns_zone_id ]; then
  echo "DNS zone $HC_NAME.$HYPERSHIFT_BASEDOMAIN is not created properly as it is not possesing any ID."
  exit 1
else 
  echo "DNS zone $HC_NAME.$HYPERSHIFT_BASEDOMAIN is created successfully in the instance $infra_name-dns."
fi

echo "Adding VPC network $infra_name-vpc to the DNS zone $HC_NAME.$HYPERSHIFT_BASEDOMAIN"
dns_network_state=$(ibmcloud dns permitted-network-add $dns_zone_id --type vpc --vpc-crn $vpc_crn -i $infra_name-dns --output JSON | jq -r '.state')
if [ "$dns_network_state" != "ACTIVE" ]; then
  echo "VPC network $infra_name-vpc which is added to the DNS zone $HC_NAME.$HYPERSHIFT_BASEDOMAIN is not in ACTIVE state."
  exit 1
else 
  echo "VPC network $infra_name-vpc is successfully added to the DNS zone $HC_NAME.$HYPERSHIFT_BASEDOMAIN."
  echo "DNS zone $HC_NAME.$HYPERSHIFT_BASEDOMAIN is in the ACTIVE state."
fi

echo "Fetching the hosted cluster IP address for resolution"
hc_url=$(cat ${SHARED_DIR}/nested_kubeconfig | awk '/server/{print $2}' | cut -c 9- | cut -d ':' -f 1)
hc_ip=$(dig +short $hc_url | head -1)

echo "Adding A records in the DNS zone $HC_NAME.$HYPERSHIFT_BASEDOMAIN to resolve the api URLs of hosted cluster to the hosted cluster IP."
ibmcloud dns resource-record-create $dns_zone_id --type A --name "api" --ipv4 $hc_ip -i $infra_name-dns
ibmcloud dns resource-record-create $dns_zone_id --type A --name "api-int" --ipv4 $hc_ip -i $infra_name-dns
if [ $? -eq 0 ]; then
  echo "Successfully added the A record of zVSI compute node IP to resolve the hosted cluster apis."
else 
  echo "A record addition is not successful."
  exit 1
fi

echo "Creating origin pool in the DNS instances for load balancing the compute nodes"
pool_id=$(ibmcloud dns glb-pool-create --name $infra_name-pool --origins name=$infra_name-compute-0,address=${zvsi_rip_list[0]},enabled=true --origins name=$infra_name-compute-1,address=${zvsi_rip_list[1]},enabled=true -i $infra_name-dns --output json | jq -r '.id')
pool_state=$(ibmcloud dns glb-pool $pool_id -i $infra_name-dns --output json | jq -r '.health')
if [ "$pool_state" == "HEALTHY" ]; then
  echo "$infra_name-pool origin pool is created successfully and in healthy state."
else 
  echo "Origin pool $infra_name-pool is not in healthy state under DNS instance $infra_name-dns."
  exit 1
fi

echo "Creating Load balancer for workload distribution on compute nodes"
lb_state=$(ibmcloud dns glb-create $dns_zone_id --name '*.apps' --default-pools $pool_id --fallback-pool $pool_id -i $infra_name-dns --output json | jq -r '.health')
if [ "$lb_state" == "HEALTHY" ]; then
  echo "*.apps load balancing is created successfully and in healthy state."
else 
  echo "Load balancer *.apps is not in healthy state under DNS instance $infra_name-dns."
  exit 1
fi

# Generating script for agent bootup execution on zVSI
initrd_url=$(oc get infraenv/${HC_NAME} -n $hcp_ns -o json | jq -r '.status.bootArtifacts.initrd')
export initrd_url
kernel_url=$(oc get infraenv/${HC_NAME} -n $hcp_ns -o json | jq -r '.status.bootArtifacts.kernel')
export kernel_url
rootfs_url=$(oc get infraenv/${HC_NAME} -n $hcp_ns -o json | jq -r '.status.bootArtifacts.rootfs')
export rootfs_url
ssh_key_string=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-key")
export ssh_key_string
tmp_ssh_key="/tmp/httpd-vsi-key"
envsubst <<"EOF" >${tmp_ssh_key}
-----BEGIN OPENSSH PRIVATE KEY-----
${ssh_key_string}

-----END OPENSSH PRIVATE KEY-----
EOF
chmod 0600 ${tmp_ssh_key}
ssh_options=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=60' -i "${tmp_ssh_key}")
echo "Downloading the rootfs image locally and transferring to HTTPD server"
curl -k -L --output $HOME/rootfs.img "$rootfs_url"
scp "${ssh_options[@]}" $HOME/rootfs.img root@$httpd_vsi_ip:/var/www/html/rootfs.img 
ssh "${ssh_options[@]}" root@$httpd_vsi_ip "chmod 644 /var/www/html/rootfs.img"
echo "Downloading the setup script for pxeboot of agents"
curl -k -L --output $HOME/setup_pxeboot.sh "http://$httpd_vsi_ip:80/setup_pxeboot.sh"
minitrd_url="${initrd_url//&/\\&}"                                 # Escaping & while replacing the URL
export minitrd_url
mkernel_url="${kernel_url//&/\\&}"                                 # Escaping & while replacing the URL
export mkernel_url
sed -i "s|INITRD_URL|${minitrd_url}|" $HOME/setup_pxeboot.sh 
sed -i "s|KERNEL_URL|${mkernel_url}|" $HOME/setup_pxeboot.sh 
sed -i "s|HTTPD_VSI_IP|${httpd_vsi_ip}|" $HOME/setup_pxeboot.sh 
chmod 700 $HOME/setup_pxeboot.sh

# Booting up zVSIs as agents
for fip in "${zvsi_fip_list[@]}"; do
  echo "Transferring the setup script to zVSI $fip"
  scp "${ssh_options[@]}" $HOME/setup_pxeboot.sh core@$fip:/var/home/core/setup_pxeboot.sh
  echo "Triggering the script in the zVSI $fip"
  ssh "${ssh_options[@]}" core@$fip "/var/home/core/setup_pxeboot.sh" &
  sleep 60
  echo "Successfully booted the zVSI $fip as agent"
done

# Deleting the resources downloaded in the pod
rm -f $HOME/setup_pxeboot.sh  $HOME/rootfs.img

# Wait for agents to join (max: 20 min)
for ((i=50; i>=1; i--)); do
  agents_count=$(oc get agents -n $hcp_ns --no-headers | wc -l)
  if [ "$agents_count" -eq ${HYPERSHIFT_NODE_COUNT} ]; then
    echo "$(date) Agents got attached successfully"
    break
  elif [ "$i" -eq 1 ]; then
    echo "[ERROR] Only $agents_count Agents joined the cluster even after 20 mins..., 0 retries left"
    exit 1
  else
    echo "Waiting for agents to join the cluster..., $i retries left"
  fi
  sleep 25
done

# Approve agents 
echo "$(date) Patching the agents to the hosted control plane"
agents=$(oc get agents -n $hcp_ns --no-headers | awk '{print $1}')
agents=$(echo "$agents" | tr '\n' ' ')
IFS=' ' read -ra agents_list <<< "$agents"
for ((i=0; i<$HYPERSHIFT_NODE_COUNT; i++)); do
  oc -n $hcp_ns patch agent ${agents_list[i]} -p "{\"spec\":{\"approved\":true,\"hostname\":\"compute-$i.${HYPERSHIFT_BASEDOMAIN}\"}}" --type merge
done

# Scaling up nodepool
oc -n $HC_NS scale nodepool $HC_NAME --replicas $HYPERSHIFT_NODE_COUNT

# Waiting for compute nodes to get ready
echo "$(date) Patched the agents, waiting for the installation to get completed on them"
oc wait --all=true agent -n $hcp_ns --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster --timeout=45m
echo "$(date) All the agents are attached as compute nodes to the hosted control plane"

# Verifying the compute nodes status
echo "$(date) Checking the compute nodes in the hosted control plane"
oc get no --kubeconfig="${SHARED_DIR}/nested_kubeconfig"
oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" wait --all=true co --for=condition=Available=True --timeout=30m
echo "$(date) Successfully completed the e2e creation chain"
