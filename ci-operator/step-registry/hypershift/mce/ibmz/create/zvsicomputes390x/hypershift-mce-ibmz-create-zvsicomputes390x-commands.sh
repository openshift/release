#!/bin/bash

set -x


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

MGMT_CLUSTER_NAME=$(cat "$SHARED_DIR/mgmt_cluster_name")
export MGMT_CLUSTER_NAME

VPC_NAME="$MGMT_CLUSTER_NAME-vpc"

# Getting ssh info
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


# Installing CLI tools
set -e
echo "Installing required CLI tools"
mkdir -p /tmp/bin
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
  mkdir -p /tmp/ibm_cloud_cli
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

# Targetting the resource group
ibmcloud target -g $infra_name-rg


# Function to check if a value is added to a given array
check_value_in_array() {
    local value=$1
    shift
    local array=("$@")

    for element in "${array[@]}"; do
        if [[ "$element" == "$value" ]]; then
           return 0
           break
        fi
    done

    return 1
}


# Function to check if a resource exists
resource_exists() {
    local resource_type=$1
    local resource_name=$2

    if ibmcloud is $resource_type $resource_name >/dev/null 2>&1; then
        check_resource_active $resource_type $resource_name
        return 0
    else
        echo -e "\n$resource_type $resource_name does not exist, triggering the creation now..."
        return 1
    fi
}

# Function to check if a resource is in the active state
check_resource_active() {
    local resource_type=$1
    local resource_name=$2

    state=$(ibmcloud is $resource_type $resource_name --output JSON | jq -r '.status')
    if [ "$state" != "available" ] && [ "$state" != "running" ]; then
        echo "$resource_type $resource_name exists but is in state $state"
        exit 1
    else 
        echo -e "\n$resource_type $resource_name is in $state state."
    fi
}

create_vsi() {
    local VSI_NAME=$1
    local ZONE=$2
    local PROFILE=$3
    local SUBNET_NAME=$4
    local IMAGE_NAME=$5
    local SSH_KEY_NAME=$6
    local SG_NAME=$7

    echo -e "\n📌 ------ VSI : $VSI_NAME ------" 

    if ! ibmcloud is vni $VSI_NAME-vni >/dev/null 2>&1; then
        echo -e "\nVirtual Network Interface $VSI_NAME-vni does not exists in the $VPC_NAME vpc, creating now..."
        ibmcloud is vnic --name "$VSI_NAME-vni" --sgs "$SG_NAME" --vpc "$VPC_NAME" --subnet "$SUBNET_NAME"
    else
        echo -e "\nVirtual Network Interface $VSI_NAME-vni already exists in the $VPC_NAME vpc, Skipping the creation..."
    fi

    if ! resource_exists "instance" $VSI_NAME; then
        ibmcloud is instance-create "$VSI_NAME" "$VPC_NAME" "$ZONE" "$PROFILE" "$SUBNET_NAME" --image "$IMAGE_NAME" --keys "$SSH_KEY_NAME" --pnac-vni "$VSI_NAME-vni"
        echo "Waiting for the $VSI_NAME VSI to be ready under 2 minutes ⏳..."
        for i in {1..13}; do
            state=$(ibmcloud is instance $VSI_NAME --output JSON | jq -r '.status')
            if [ "$state" != "available" ] && [ "$state" != "running" ]; then
                if [ $i -eq 13 ]; then
                    echo "❌ Error: VSI $VSI_NAME creation is not successful even after 2 minutes. Exiting now."
                    exit 1
                fi
                echo "🔄 Retry $i/12: Waiting for VSI $VSI_NAME to be in ready state, sleeping for 10 seconds ⏳..."
                sleep 10
            else
                echo "✅ Successfully created the VSI: $VSI_NAME in VPC: $VPC_NAME"
                break
            fi
        done
    fi

    if ! resource_exists "floating-ip" ${VSI_NAME}-ip; then
        vni_id=$(ibmcloud is instance $VSI_NAME | awk '/Primary/{print $7}')
        ibmcloud is floating-ip-reserve ${VSI_NAME}-ip --nic $vni_id
        check_resource_active "floating-ip" ${VSI_NAME}-ip
    fi

    echo -e "\nFetching the Reserved IP, Floating IP and MAC Address of the VSI $VSI_NAME"
    RESERVED_IP=$(ibmcloud is instance $VSI_NAME --output JSON | jq -r '.network_interfaces[0].primary_ip.address')
    FLOATING_IP=$(ibmcloud is floating-ip ${VSI_NAME}-ip --output JSON | jq -r '.address')
    until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$FLOATING_IP -i /tmp/httpd-vsi-key 'echo'; do
       echo "Waiting for SSH on $VSI_NAME to respond ⏳..."
       sleep 10
    done
    MAC_ADDR=$(ssh -o StrictHostKeyChecking=no root@$FLOATING_IP "ip link show | awk '/ether/{print \$2}'")

    case "$VSI_NAME" in
        *-control-*|*-sno*)
            if ! check_value_in_array "$RESERVED_IP" "${CONTROL_RIP[@]}"; then
                CONTROL_RIP+=("$RESERVED_IP")
            fi
            if ! check_value_in_array "$FLOATING_IP"  "${CONTROL_FIP[@]}"; then
                CONTROL_FIP+=("$FLOATING_IP")
            fi
            if ! check_value_in_array "$MAC_ADDR" "${CONTROL_MAC[@]}"; then
                CONTROL_MAC+=("$MAC_ADDR")
            fi
            ;;
        *-compute-*)
            if ! check_value_in_array "$RESERVED_IP" "${COMPUTE_RIP[@]}"; then
                COMPUTE_RIP+=("$RESERVED_IP")
            fi
            if ! check_value_in_array "$FLOATING_IP"  "${COMPUTE_FIP[@]}"; then
                COMPUTE_FIP+=("$FLOATING_IP")
            fi
            if ! check_value_in_array "$MAC_ADDR"  "${COMPUTE_MAC[@]}"; then
                COMPUTE_MAC+=("$MAC_ADDR")
            fi
            ;;
    esac

    echo -e "\nVSI $VSI_NAME with IP $FLOATING_IP and MAC address $MAC_ADDR is created."
}

create_dns_records() { 
    local record_name=$1
    local dns_id=$2
    local dns_zone_id=$3
    local resolution_ip=$4

    # Create A record
    echo -e "\nCreating A record for $record_name.$HC_NAME.$hcp_domain to point to $resolution_ip"
    # Check if the A record exists before creating it
    if ! ibmcloud dns resource-records $dns_zone_id -i $dns_id | grep "$record_name.$HC_NAME.$hcp_domain" >/dev/null 2>&1; then
        echo -e "\nAdding A record $record_name.$HC_NAME in the DNS Zone..."
        ibmcloud dns resource-record-create $dns_zone_id --type A --name "$record_name.$HC_NAME" --ipv4 $resolution_ip -i $dns_id
        echo "A record for $record_name.$HC_NAME created successfully."
    else
        echo -e "\nA record for $record_name.$HC_NAME already exists, skipping creation."
        ibmcloud dns resource-records $dns_zone_id -i $dns_id | grep "$record_name.$HC_NAME"
    fi
}

create_sg_rule() {
    local sg_name=$1
    local direction=$2
    local protocol=$3
    local port_min=$4
    local port_max=$5

    # Check if the rule exists
    if [ "$protocol" == "tcp" ]; then
        rule_exists=$(ibmcloud is sg-rules $sg_name --output JSON | jq -r --arg port_min "$port_min" --arg port_max "$port_max" --arg direction "$direction" --arg protocol "$protocol" \
             '.[] | select(.port_min == ($port_min|tonumber) and .port_max == ($port_max|tonumber) and .direction == $direction and .protocol == $protocol)')
    else
        rule_exists=$(ibmcloud is sg-rules $sg_name --output JSON | jq -r --arg direction "$direction" --arg protocol "$protocol" \
                        '.[] | select(.direction == $direction and .protocol == $protocol)')
    fi

    if [ -n "$rule_exists" ]; then
        echo -e "\n$direction rule for port $port_min with protocol $protocol already exists. Skipping creation..."
    else
        echo -e "\n$direction rule does not exist for $port_min with protocol $protocol. Creating it..."
        extra_args=""
        case "$protocol" in
            "tcp")
                extra_args="--port-min $port_min --port-max $port_max"
                ;;
            "icmp")
                extra_args="--icmp-type $port_min --icmp-code $port_max"
                ;;
            "all")
                if [ "$direction" == "inbound" ]; then
                    extra_args="--remote $sg_name"
                fi
                ;;
        esac
        ibmcloud is sg-rulec $sg_name $direction $protocol $extra_args
    fi
}

# Create security group rules to open the port range 30000-33000 for TCP traffic
sg_name="$MGMT_CLUSTER_NAME-sg"
create_sg_rule $sg_name inbound tcp 30000 33000
create_sg_rule $sg_name inbound tcp 3128 3128

# Create Bastion Node
create_vsi "$infra_name-bastion" "$IC_REGION-2" "bx2-2x8" "$MGMT_CLUSTER_NAME-sn-2" "ibm-redhat-9-6-minimal-amd64-3" "hcp-prow-ci-dnd-key" "$sg_name"

# Create Compute Nodes

for i in $(seq 1 $HYPERSHIFT_NODE_COUNT); do
    ZONE="$IC_REGION-2"
    SUBNET_NAME="$MGMT_CLUSTER_NAME-sn-2"
    create_vsi "$infra_name-compute-$i" "$ZONE" "$ZVSI_PROFILE" "$SUBNET_NAME" "$ZVSI_IMAGE" "hcp-prow-ci-dnd-key" "$sg_name"
done

BASTION_FIP=$(ibmcloud is floating-ip $infra_name-bastion-ip --output JSON | jq -r '.address')
BASTION_RIP=$(ibmcloud is instance $infra_name-bastion --output JSON | jq -r '.network_interfaces[0].primary_ip.address')

# Fetching the Reserved IPs of the hcp compute nodes
ZVSI_COMPUTE_RIP=()
for i in $(seq 1 $HYPERSHIFT_NODE_COUNT); do
    ZVSI_COMPUTE_RIP+=("$(ibmcloud is instance $infra_name-compute-$i --output JSON | jq -r '.network_interfaces[0].primary_ip.address')")
done

HUB_COMPUTE_RIPS=()
# Fetching the number of compute nodes in the hub cluster
HUB_COMPUTE_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker= \
  -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | wc -l)


# Fetching the Reserved IPs of the hub cluster compute nodes
for i in $(seq 1 "$HUB_COMPUTE_COUNT"); do
    HUB_COMPUTE_RIPS+=("$(ibmcloud is instance hcp-s390x-mgmt-ci-$job_id-compute-$i --output JSON | jq -r '.network_interfaces[0].primary_ip.address')")
done




ssh "${ssh_options[@]}" root@$BASTION_FIP '
  yum install -y httpd &&
  systemctl enable httpd &&
  systemctl start httpd &&
  echo "Configuring Web server with custom listeners on bastion" &&
  if ! grep -q "8080" "/etc/httpd/conf/httpd.conf"; then
     sed -i "s/80/8080/g" /etc/httpd/conf/httpd.conf
  fi &&
  if ! grep -q "8443" "/etc/httpd/conf/httpd.conf"; then
     sed -i "s/443/8443/g" /etc/httpd/conf/httpd.conf
  fi &&
  systemctl restart httpd &&
  systemctl status httpd --no-pager
'
ssh "${ssh_options[@]}" root@$BASTION_FIP "systemctl is-active --quiet httpd"
if [ $? -ne 0 ]; then
  echo 'HTTPD server configuration failed, httpd serivce not running'
  exit 1
else
  echo 'HTTPD server configuration succeeded'
fi

ssh "${ssh_options[@]}" root@$BASTION_FIP "yum install -y haproxy ; systemctl enable haproxy ; systemctl start haproxy"




# Configiring HAProxy on Bastion
echo "Configuring HAProxy on Bastion"
cat <<HAPROXY_CFG > haproxy.cfg
listen stats
   bind :9000
   mode http
   stats enable
   stats uri /
   monitor-uri /healthz
frontend hub-api-server
   mode tcp
   option tcplog
   bind ${BASTION_RIP}:30000-33000 # Bastion IP Address
   default_backend hub-api-server
backend hub-api-server
   mode tcp
   balance source
HAPROXY_CFG

# Append backend servers
for i in $(seq 1 "$HUB_COMPUTE_COUNT"); do
  index=$((i - 1))
  echo "   server ${MGMT_CLUSTER_NAME}-compute-${i} ${HUB_COMPUTE_RIPS[$index]}" >> haproxy.cfg
done

cat <<HAPROXY_CFG >> haproxy.cfg
listen hcp-console
    mode tcp
    bind ${BASTION_RIP}:443
    bind ${BASTION_RIP}:80
HAPROXY_CFG

# Append hypershift nodes
for i in $(seq 1 ${HYPERSHIFT_NODE_COUNT}); do
  index=$((i - 1))
  echo "   server ${HC_NAME}-compute-${i} ${ZVSI_COMPUTE_RIP[$index]}" >> haproxy.cfg
done


# Sending haproxy file to bastion and restarting the service
scp "${ssh_options[@]}" haproxy.cfg root@$BASTION_FIP:/etc/haproxy/haproxy.cfg
ssh "${ssh_options[@]}" root@$BASTION_FIP "systemctl restart haproxy"
ssh "${ssh_options[@]}" root@$BASTION_FIP "systemctl is-active --quiet haproxy"
if [ $? -ne 0 ]; then
  echo 'HAProxy configuration failed, haproxy serivce not running'
  exit 1
else
  echo 'HAProxy configuration succeeded'
fi



# Configuring DNS

# Getting the IBM Cloud DNS instance ID
DNS_ID=$(ibmcloud dns instance $MGMT_CLUSTER_NAME-dns --output JSON | jq -r '.guid')

# Create DNS zone if not exists
if ! ibmcloud dns zones -i $DNS_ID | grep "$hcp_domain" >/dev/null 2>&1; then
    echo -e "\nCreating DNS Zone $hcp_domain in the $MGMT_CLUSTER_NAME-dns instance..."
    DNS_ZONE_ID=$(ibmcloud dns zone-create $hcp_domain -i $DNS_ID --output JSON | jq -r '.id')
else
    echo -e "\nDNS zone $hcp_domain already exists, skipping creation."
    ibmcloud dns zones -i $DNS_ID
    DNS_ZONE_ID=$(ibmcloud dns zones -i $DNS_ID --output JSON | jq -r --arg ZONE "$hcp_domain" '.[] | select(.name==$ZONE) | .id')
fi

# Create A records for API and Ingress
create_dns_records "api" $DNS_ID $DNS_ZONE_ID $BASTION_RIP
create_dns_records "api-int" $DNS_ID $DNS_ZONE_ID $BASTION_RIP
create_dns_records "*.apps" $DNS_ID $DNS_ZONE_ID $BASTION_RIP

# Adding VPC network to the DNS zone

vpc_crn=$(ibmcloud is vpc $MGMT_CLUSTER_NAME-vpc | awk '/CRN/{print $2}')
echo "Adding VPC network $MGMT_CLUSTER_NAME-vpc to the DNS zone $hcp_domain"
dns_network_state=$(ibmcloud dns permitted-network-add $DNS_ZONE_ID --type vpc --vpc-crn $vpc_crn -i $MGMT_CLUSTER_NAME-dns --output JSON | jq -r '.state')
if [ "$dns_network_state" != "ACTIVE" ]; then
  echo "VPC network $MGMT_CLUSTER_NAME-vpc which is added to the DNS zone $HC_NAME.$hcp_domain is not in ACTIVE state."
  exit 1
else 
  echo "VPC network $MGMT_CLUSTER_NAME-vpc is successfully added to the DNS zone $hcp_domain."
  echo "DNS zone $hcp_domain is in the ACTIVE state."
fi



# Booting Agents 
# Generating script for agent bootup execution on zVSI
initrd_url=$(oc get infraenv/${HC_NAME} -n $hcp_ns -o json | jq -r '.status.bootArtifacts.initrd')
export initrd_url
kernel_url=$(oc get infraenv/${HC_NAME} -n $hcp_ns -o json | jq -r '.status.bootArtifacts.kernel')
export kernel_url
rootfs_url=$(oc get infraenv/${HC_NAME} -n $hcp_ns -o json | jq -r '.status.bootArtifacts.rootfs')
export rootfs_url

echo "Downloading the rootfs image locally and transferring to HTTPD server"
curl -k -L --output $HOME/rootfs.img "$rootfs_url"
scp "${ssh_options[@]}" $HOME/rootfs.img root@$BASTION_FIP:/var/www/html/rootfs.img 
ssh "${ssh_options[@]}" root@$BASTION_FIP "chmod 644 /var/www/html/rootfs.img"

# Downloading the script to trigger pxeboot of agents
echo "Downloading the setup script for pxeboot of agents"
git clone -c "core.sshCommand=ssh ${ssh_options[*]}" git@github.ibm.com:OpenShift-on-Z/hosted-control-plane.git &&
cp hosted-control-plane/.archive/trigger_pxeboot.sh $HOME/trigger_pxeboot.sh

minitrd_url="${initrd_url//&/\\&}"                                 # Escaping & while replacing the URL
export minitrd_url
mkernel_url="${kernel_url//&/\\&}"                                 # Escaping & while replacing the URL
export mkernel_url
rootfs_url_httpd="http://$BASTION_RIP:8080/rootfs.img"
export rootfs_url_httpd
sed -i "s|INITRD_URL|${minitrd_url}|" $HOME/trigger_pxeboot.sh 
sed -i "s|KERNEL_URL|${mkernel_url}|" $HOME/trigger_pxeboot.sh 
sed -i "s|ROOTFS_URL|${rootfs_url_httpd}|" $HOME/trigger_pxeboot.sh  
chmod 700 $HOME/trigger_pxeboot.sh



# Fetching the Floating IPs of the hcp compute nodes
zvsi_fip_list=()
for i in $(seq 1 $HYPERSHIFT_NODE_COUNT); do
    zvsi_fip_list+=("$(ibmcloud is floating-ip $infra_name-compute-$i-ip --output JSON | jq -r '.address')")
done

# Booting up zVSIs as agents
for fip in "${zvsi_fip_list[@]}"; do
  echo "Transferring the setup script to zVSI $fip"
  scp "${ssh_options[@]}" $HOME/trigger_pxeboot.sh root@$fip:/root/trigger_pxeboot.sh
  echo "Triggering the script in the zVSI $fip"
  ssh "${ssh_options[@]}" root@$fip "/root/trigger_pxeboot.sh" &
  sleep 60
  echo "Successfully booted the zVSI $fip as agent"
done

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
scp "${ssh_options[@]}" $HOME/setup_proxy.sh root@$BASTION_FIP:/root/setup_proxy.sh
echo "Triggering the proxy server setup on Bastion"
ssh "${ssh_options[@]}" root@$BASTION_FIP "/root/setup_proxy.sh"

cat <<EOF > "${SHARED_DIR}/proxy-conf.sh"
export HTTP_PROXY=http://${BASTION_FIP}:3128/
export HTTPS_PROXY=http://${BASTION_FIP}:3128/
export NO_PROXY="static.redhat.com,redhat.io,amazonaws.com,r2.cloudflarestorage.com,quay.io,openshift.org,openshift.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"
export http_proxy=http://${BASTION_FIP}:3128/
export https_proxy=http://${BASTION_FIP}:3128/
export no_proxy="static.redhat.com,redhat.io,amazonaws.com,r2.cloudflarestorage.com,quay.io,openshift.org,openshift.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"
EOF



# Sourcing the proxy settings for the next steps
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi



# Verifying the compute nodes status
echo "$(date) Checking the compute nodes in the hosted control plane"
oc get no --kubeconfig="${SHARED_DIR}/nested_kubeconfig"
oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" wait --all=true co --for=condition=Available=True --timeout=30m

echo "$(date) Successfully completed the e2e creation chain"