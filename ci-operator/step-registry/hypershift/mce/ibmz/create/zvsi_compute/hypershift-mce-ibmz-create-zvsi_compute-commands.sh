#!/bin/bash

set -xuo pipefail

infra_name="hcp-ci-$(echo -n $PROW_JOB_ID|cut -c-8)"
plugins_list=("vpc-infrastructure" "cloud-object-storage" "cloud-dns-services")
hc_ns="hcp-ci"
hc_name="agent-ibmz"
hcp_ns=$hc_ns-$hc_name

# Installing CLI tools
set -e
echo "Installing required CLI tools"
sudo yum install -y wget jq bind-utils
set +e
echo "Checking if ibmcloud CLI is installed."
ibmcloud -v
if [ $? -eq 0 ]; then
  echo "ibmcloud CLI is already installed."
else
  set -e
  echo "ibmcloud CLI is not installed. Installing it now..."
  wget -P $HOME/ https://download.clis.cloud.ibm.com/ibm-cloud-cli/$IBMCLOUD_CLI_VERSION/binaries/IBM_Cloud_CLI_${IBMCLOUD_CLI_VERSION}_linux_amd64.tgz
  tar -xvf $HOME/IBM_Cloud_CLI_${IBMCLOUD_CLI_VERSION}_linux_amd64.tgz
  cp $HOME/IBM_Cloud_CLI/ibmcloud /usr/bin/
fi 

# Login to the IBM Cloud
set -e
echo "Logging into IBM Cloud by targetting the $IC_REGION region"
ibmcloud login --apikey $IC_APIKEY -r $IC_REGION
set +e
echo "Checking if the $plugins_list plugins are installed."
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
ibmcloud is key-create $infra_name-key @$HOME/.ssh/id_rsa.pub --resource-group-name $infra_name-rg
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
  vol_json=$(jq -n --arg v1 "$infra_name-compute-$i-volume" '{"name": $v1, "volume": {"name": $v1, "capacity": 250, "profile": {"name": "general-purpose"}}}')
  ibmcloud is instance-create $infra_name-compute-$i $infra_name-vpc $IC_REGION-1 $ZVSI_PROFILE $infra_name-sn --image $zvsi_image_id --keys $infra_name-key --resource-group-name $infra_name-rg --boot-volume $vol_json
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

echo "Creating the DNS zone $hc_name.$BASE_DOMAIN in the instance $infra_name-dns."
dns_zone_id=$(ibmcloud dns zone-create "$hc_name.$BASE_DOMAIN" -i $infra_name-dns --output JSON | jq -r '.id')
if [ -z $dns_zone_id ]; then
  echo "DNS zone $hc_name.$BASE_DOMAIN is not created properly as it is not possesing any ID."
  exit 1
else 
  echo "DNS zone $hc_name.$BASE_DOMAIN is created successfully in the instance $infra_name-dns."
fi

echo "Adding VPC network $infra_name-vpc to the DNS zone $hc_name.$BASE_DOMAIN."
dns_network_state=$(ibmcloud dns permitted-network-add $dns_zone_id --type vpc --vpc-crn $vpc_crn -i $infra_name-dns --output JSON | jq -r '.state')
if [ "$dns_network_state" != "ACTIVE" ]; then
  echo "VPC network $infra_name-vpc which is added to the DNS zone $hc_name.$BASE_DOMAIN is not in ACTIVE state."
  exit 1
else 
  echo "VPC network $infra_name-vpc is successfully added to the DNS zone $hc_name.$BASE_DOMAIN."
  echo "DNS zone $hc_name.$BASE_DOMAIN is in the ACTIVE state."
fi

echo "Fetching the hosted cluster IP address for resolution"
hc_ip=$(dig +short $(cat $SHARED_DIR/${hc_name}_kubeconfig | awk '/server/{print $2}' | cut -c 9- | cut -d ':' -f 1))

echo "Adding A records in the DNS zone $hc_name.$BASE_DOMAIN to resolve the api URLs of hosted cluster to the hosted cluster IP."
ibmcloud dns resource-record-create $dns_zone_id --type A --name "api" --ipv4 $hc_ip -i $infra_name-dns
ibmcloud dns resource-record-create $dns_zone_id --type A --name "api-int" --ipv4 $hc_ip -i $infra_name-dns
if [ $? -eq 0 ]; then
  echo "Successfully added the A record of zVSI compute node IP to resolve the hosted cluster apis."
else 
  echo "A record addition is not successful."
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
  pool_id=$()
else 
  echo "Load balancer *.apps is not in healthy state under DNS instance $infra_name-dns."
  exit 1
fi

# Downloading the ipxe-script
ipxe_script_url=$(oc get infraenv $hc_name -n $hcp_ns -ojsonpath='{.status.bootArtifacts.ipxeScript}')
wget -O "$HOME/${hc_name}-ipxe-script" "${ipxe_script_url}"
echo "HC_NAME $hc_name" >> $HOME/$hc_name-ipxe-script

# Booting up zVSI as agents
for fip in "${zvsi_fip_list[@]}"; do
  echo "Transferring the ipxe-script to zVSI for agent bootup"
  SSH_OPTIONS='PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null'
  scp -o ${SSH_OPTIONS} $HOME/$hc_name-ipxe-script core@$fip:$HOME/$hc_name-ipxe-script
  echo "Logging into the zVSI $fip"
  ssh -o ${SSH_OPTIONS} core@$fip
  export HC_NAME=$(cat ipxe-script | awk '/HC_NAME/{print $2}')
  initrd_url=$(cat $HOME/$HC_NAME-ipxe-script | awk '/initrd --name/{print $4}')
  kernel_url=$(cat $HOME/$HC_NAME-ipxe-script | awk '/kernel/{print $2}')
  rootfs_url=$(cat $HOME/$HC_NAME-ipxe-script | awk '/kernel/{print $4}' | cut -d '=' -f 2,3,4)
  curl -k -L -o "$HOME/initrd.img" "$initrd_url"
  curl -k -L -o "$HOME/kernel.img" "$kernel_url"
  sudo kexec -l $HOME/kernel.img --initrd="$HOME/initrd.img" --append="rd.neednet=1 coreos.live.rootfs_url=$rootfs_url random.trust_cpu=on rd.luks.options=discard ignition.firstboot ignition.platform.id=metal console=tty1 console=ttyS1,115200n8"
  sudo kexec -e &
  exit
done

# Wait for agents to join (max: 20 min)
for ((i=50; i>=1; i--)); do
  agents_count=$(oc get agents -n $hcp_ns --no-headers | wc -l)
  if [ "$agents_count" -eq ${HYPERSHIFT_NODE_COUNT} ]; then
    echo "Agents attached"
    break
  else
    echo "Waiting for agents to join the cluster..., $i retries left"
  fi
  sleep 25
done

# Approve agents 
agents=$(oc get agents -n $hcp_ns --no-headers | awk '{print $1}')
agents=$(echo "$agents" | tr '\n' ' ')
IFS=' ' read -ra agents_list <<< "$agents"
for ((i=0; i<$HYPERSHIFT_NODE_COUNT; i++)); do
     oc -n ${$hcp_ns} patch agent ${agents_list[i]} -p "{\"spec\":{\"installation_disk_id\":\"/dev/vda\",\"approved\":true,\"hostname\":\"compute-${i}.${HYPERSHIFT_BASEDOMAIN}\"}}" --type merge
done

# Scaling up nodepool
oc -n $hc_ns scale nodepool $hc_name --replicas $HYPERSHIFT_NODE_COUNT

# Wait for agent installation to get completed
echo "$(date) Approved the agents, waiting for the installation to get completed on them"
oc wait --all=true agent -n $hcp_ns --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster --timeout=45m

# Waiting for compute nodes to attach (max: 30 min)
for ((i=60; i>=1; i--)); do
  node_count=$(oc get no --kubeconfig="${SHARED_DIR}/${hc_name}_kubeconfig" --no-headers | wc -l)
  if [ "$node_count" -eq $HYPERSHIFT_NODE_COUNT ]; then
    echo "Compute nodes attached"
    break
  else
    echo "Waiting for Compute nodes to join..., $i retries left"
  fi
  sleep 30
done

# Waiting for compute nodes to be ready (max: 12 min)
for ((i=30; i>=1; i--)); do
  not_ready_count=$(oc get no --kubeconfig="${SHARED_DIR}/${hc_name}_kubeconfig" --no-headers | awk '{print $2}' | grep -v 'Ready' | wc -l)
  if [ "$not_ready_count" -eq 0 ]; then
    echo "All Compute nodes are Ready"
    break
  else
    echo "Waiting for Compute nodes to be Ready..., $i retries left"
  fi
  sleep 25
done