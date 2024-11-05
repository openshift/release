#!/bin/bash

set -x

# Session variables
HC_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HC_NAME
job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export job_id
plugins_list=("vpc-infrastructure" "cloud-dns-services")
infra_name="hcp-ci-$job_id"
export infra_name
hcp_ns=$HC_NS-$HC_NAME
export hcp_ns
hcp_domain="$job_id-$HYPERSHIFT_BASEDOMAIN"
export hcp_domain
IC_API_KEY=$(cat "${AGENT_IBMZ_CREDENTIALS}/ibmcloud-apikey")
export IC_API_KEY

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

# Create a bastion node in the same VPC for configuring proxy server
set -e
echo "Triggering the $infra_name-bastion VSI creation on IBM Cloud in the VPC $infra_name-vpc"
ibmcloud is instance-create $infra_name-bastion $infra_name-vpc $IC_REGION-1 bx2-2x8 $infra_name-sn --image ibm-redhat-9-2-minimal-amd64-2 --keys hcp-prow-ci-dnd-key --resource-group-name $infra_name-rg
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
echo "Adding an inbound rule in $infra_name-bastion instance security group for configuring and accessing proxy server"
ibmcloud is sg-rulec $bsg_name inbound tcp --port-min 3128 --port-max 3128
bvsi_rip=$(ibmcloud is instance $infra_name-bastion --output json | jq -r '.primary_network_interface.primary_ip.address')


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

# Create zVSI compute nodes
set -e
zvsi_rip_list=()
zvsi_fip_list=()
for ((i = 0; i < $HYPERSHIFT_NODE_COUNT ; i++)); do
  echo "Triggering the $infra_name-compute-$i zVSI creation on IBM Cloud in the VPC $infra_name-vpc"
  vol_json=$(jq -n -c --arg volume "$infra_name-compute-$i-volume" '{"name": $volume, "volume": {"name": $volume, "capacity": 250, "profile": {"name": "general-purpose"}}}')
  ibmcloud is instance-create $infra_name-compute-$i $infra_name-vpc $IC_REGION-1 $ZVSI_PROFILE $infra_name-sn --image $ZVSI_IMAGE --keys hcp-prow-ci-dnd-key --resource-group-name $infra_name-rg --boot-volume $vol_json
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
  
  echo "Getting the Virtual Network Interface ID for zVSI"
  vni_id=$(ibmcloud is instance $infra_name-compute-$i | awk '/Primary/{print $7}')
  echo "Creating a Floating IP for zVSI"
  zvsi_fip=$(ibmcloud is floating-ip-reserve $infra_name-compute-$i-ip --nic $vni_id | awk '/Address/{print $2}')
  if [ -z "$zvsi_fip" ]; then
    echo "Error: Floating IP assignment failed. zvsi_fip is empty."
    exit 1
  else
    echo "Floating IP assigned to zVSI : $zvsi_fip"
  fi
  zvsi_fip_list+=("$zvsi_fip")
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

echo "Creating the DNS zone $HC_NAME.$hcp_domain in the instance $infra_name-dns."
dns_zone_id=$(ibmcloud dns zone-create "$HC_NAME.$hcp_domain" -i $infra_name-dns --output JSON | jq -r '.id')
if [ -z $dns_zone_id ]; then
  echo "DNS zone $HC_NAME.$hcp_domain is not created properly as it is not possesing any ID."
  exit 1
else 
  echo "DNS zone $HC_NAME.$hcp_domain is created successfully in the instance $infra_name-dns."
fi

echo "Adding VPC network $infra_name-vpc to the DNS zone $HC_NAME.$hcp_domain"
dns_network_state=$(ibmcloud dns permitted-network-add $dns_zone_id --type vpc --vpc-crn $vpc_crn -i $infra_name-dns --output JSON | jq -r '.state')
if [ "$dns_network_state" != "ACTIVE" ]; then
  echo "VPC network $infra_name-vpc which is added to the DNS zone $HC_NAME.$hcp_domain is not in ACTIVE state."
  exit 1
else 
  echo "VPC network $infra_name-vpc is successfully added to the DNS zone $HC_NAME.$hcp_domain."
  echo "DNS zone $HC_NAME.$hcp_domain is in the ACTIVE state."
fi

echo "Fetching the hosted cluster IP address for resolution"
hc_url=$(cat ${SHARED_DIR}/nested_kubeconfig | awk '/server/{print $2}' | cut -c 9- | cut -d ':' -f 1)
hc_ip=$(dig +short $hc_url | head -1)

echo "Adding A records in the DNS zone $HC_NAME.$hcp_domain to resolve the api URLs of hosted cluster to the hosted cluster IP."
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
echo "Configuring HTTPD server on bastion"
ssh "${ssh_options[@]}" root@$bvsi_fip "yum install -y httpd ; systemctl start httpd ; systemctl enable httpd"
ssh "${ssh_options[@]}" root@$bvsi_fip "systemctl is-active --quiet httpd"
if [ $? -ne 0 ]; then
  echo 'HTTPD server configuration failed, httpd serivce not running'
  exit 1
else
  echo 'HTTPD server configuration succeeded'
fi

echo "Downloading the rootfs image locally and transferring to HTTPD server"
curl -k -L --output $HOME/rootfs.img "$rootfs_url"
scp "${ssh_options[@]}" $HOME/rootfs.img root@$bvsi_fip:/var/www/html/rootfs.img 
ssh "${ssh_options[@]}" root@$bvsi_fip "chmod 644 /var/www/html/rootfs.img"

echo "Downloading the setup script for pxeboot of agents"
git clone -c "core.sshCommand=ssh ${ssh_options[*]}" git@github.ibm.com:OpenShift-on-Z/hosted-control-plane.git &&
cp hosted-control-plane/.archive/trigger_pxeboot.sh $HOME/trigger_pxeboot.sh

minitrd_url="${initrd_url//&/\\&}"                                 # Escaping & while replacing the URL
export minitrd_url
mkernel_url="${kernel_url//&/\\&}"                                 # Escaping & while replacing the URL
export mkernel_url
rootfs_url_httpd="http://$bvsi_rip:80/rootfs.img"
export rootfs_url_httpd
sed -i "s|INITRD_URL|${minitrd_url}|" $HOME/trigger_pxeboot.sh 
sed -i "s|KERNEL_URL|${mkernel_url}|" $HOME/trigger_pxeboot.sh 
sed -i "s|ROOTFS_URL|${rootfs_url_httpd}|" $HOME/trigger_pxeboot.sh  
chmod 700 $HOME/trigger_pxeboot.sh

# Booting up zVSIs as agents
for fip in "${zvsi_fip_list[@]}"; do
  echo "Transferring the setup script to zVSI $fip"
  scp "${ssh_options[@]}" $HOME/trigger_pxeboot.sh root@$fip:/root/trigger_pxeboot.sh
  echo "Triggering the script in the zVSI $fip"
  ssh "${ssh_options[@]}" root@$fip "/root/trigger_pxeboot.sh" &
  sleep 60
  echo "Successfully booted the zVSI $fip as agent"
done

# Deleting the resources downloaded in the pod
rm -f $HOME/trigger_pxeboot.sh  $HOME/rootfs-$PROW_JOB_ID.img
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
  oc -n $hcp_ns patch agent ${agents_list[i]} -p "{\"spec\":{\"approved\":true,\"hostname\":\"compute-$i.${hcp_domain}\"}}" --type merge
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

# Configuring proxy server on bastion 
echo "Getting management cluster basedomain to allow traffic to proxy server"
mgmt_domain=$(oc whoami --show-server | awk -F'.' '{print $(NF-1)"."$NF}' | cut -d':' -f1)

echo "Getting the proxy setup script"
cp hosted-control-plane/.archive/setup_proxy.sh $HOME/setup_proxy.sh

sed -i "s|MGMT_DOMAIN|${mgmt_domain}|" $HOME/setup_proxy.sh 
sed -i "s|HCP_DOMAIN|${hcp_domain}|" $HOME/setup_proxy.sh 
chmod 700 $HOME/setup_proxy.sh

echo "Transferring the setup script to Bastion"
scp "${ssh_options[@]}" $HOME/setup_proxy.sh root@$bvsi_fip:/root/setup_proxy.sh
echo "Triggering the proxy server setup on Bastion"
ssh "${ssh_options[@]}" root@$bvsi_fip "/root/setup_proxy.sh"

cat <<EOF> "${SHARED_DIR}/proxy-conf.sh"
export HTTP_PROXY=http://${bvsi_fip}:3128/
export HTTPS_PROXY=http://${bvsi_fip}:3128/
export NO_PROXY="static.redhat.com,redhat.io,amazonaws.com,r2.cloudflarestorage.com,quay.io,openshift.org,openshift.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"

export http_proxy=http://${bvsi_fip}:3128/
export https_proxy=http://${bvsi_fip}:3128/
export no_proxy="static.redhat.com,redhat.io,amazonaws.com,r2.cloudflarestorage.com,quay.io,openshift.org,openshift.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"
EOF
echo "$(date) Successfully completed the e2e creation chain"
