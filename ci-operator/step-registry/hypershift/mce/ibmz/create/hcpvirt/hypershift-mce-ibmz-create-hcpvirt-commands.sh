#!/bin/bash

set -x
set -e

# Update the default storage class to ocs-storagecluster-ceph-rbd
VIRT_SC="ocs-storagecluster-ceph-rbd-virtualization"
CEPH_RBD_SC="ocs-storagecluster-ceph-rbd"

echo "Removing default annotation from: $VIRT_SC"
oc annotate --overwrite sc "$VIRT_SC" \
  storageclass.kubernetes.io/is-default-class="false"

echo "Setting default StorageClass to: $CEPH_RBD_SC"
oc patch storageclass "$CEPH_RBD_SC" \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'

echo
echo "✔ Updated StorageClasses:"
oc get sc


# Hosted Control Plane parameters
HC_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HC_NAME
hcp_ns="$HC_NS-$HC_NAME"
export hcp_ns
hcp_domain=$(echo -n $PROW_JOB_ID|cut -c-8)-$HYPERSHIFT_BASEDOMAIN
export hcp_domain
CLUSTER_ARCH=s390x
export CLUSTER_ARCH

ssh_key_file="${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-pub-key"
export ssh_key_file

# Installing hypershift cli
HYPERSHIFT_CLI_NAME=hcp
echo "$(date) Installing hypershift cli"
mkdir /tmp/${HYPERSHIFT_CLI_NAME}_cli
downloadURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_CLI_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
curl -k --output /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz ${downloadURL}
tar -xvf /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz -C /tmp/${HYPERSHIFT_CLI_NAME}_cli
chmod +x /tmp/${HYPERSHIFT_CLI_NAME}_cli/${HYPERSHIFT_CLI_NAME}
export PATH=$PATH:/tmp/${HYPERSHIFT_CLI_NAME}_cli

# Installing required tools
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
curl -L https://github.com/mikefarah/yq/releases/download/v4.31.2/yq_linux_amd64 -o /tmp/bin/yq && chmod +x /tmp/bin/yq
PATH=$PATH:/tmp/bin
export PATH

set +x
# Setting up pull secret
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
cp /tmp/.dockerconfigjson /tmp/pull-secret
PULL_SECRET_FILE=/tmp/pull-secret
set -x

# Creating Kubevirt hosted cluster manifests
echo "$(date) Creating kubevirt hosted cluster manifests"
oc create ns ${hcp_ns}
mkdir /tmp/hc-manifests

# Set RENDER_COMMAND based on MCE_VERSION

# >= 2.7: "--render-sensitive --render", else: "--render"
if [[ "$(printf '%s\n' "2.7" "$MCE_VERSION" | sort -V | head -n1)" == "2.7" ]]; then
  extra_flags+="--render-sensitive --render > /tmp/hc.yaml "
else
  extra_flags+="--render > /tmp/hc.yaml "
fi

${HYPERSHIFT_CLI_NAME} create cluster kubevirt \
    --name ${HC_NAME} \
    --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} \
    --pull-secret "${PULL_SECRET_FILE}" \
    --base-domain ${hcp_domain} \
    --ssh-key ${ssh_key_file} \
    --arch ${CLUSTER_ARCH} \
    --control-plane-availability-policy ${HYPERSHIFT_CP_AVAILABILITY_POLICY} \
    --infra-availability-policy ${HYPERSHIFT_INFRA_AVAILABILITY_POLICY} \
    --namespace $HC_NS \
    --memory 8Gi \
    --cores 4 \
    --root-volume-size 60 \
    --release-image ${OCP_IMAGE_MULTI} ${extra_flags} > /tmp/hc-manifests/cluster-agent.yaml


oc apply -f /tmp/hc-manifests/cluster-agent.yaml

oc wait --timeout=15m --for=condition=Available --namespace=${HC_NS} hostedcluster/${HC_NAME}
echo "$(date) Kubevirt cluster is available"

job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export job_id
export CLUSTER_NAME="hcp-s390x-mgmt-ci-$job_id"
SSH_KEY="$HOME/$CLUSTER_NAME/.ssh/$CLUSTER_NAME-key"
HAPROXY_REMOTE_CFG="/etc/haproxy/haproxy.cfg"

# Install IBM Cloud CLI
if ! command -v ibmcloud &> /dev/null; then
    set -e
    echo "ibmcloud CLI is not installed. Installing it now..."
    mkdir /tmp/ibm_cloud_cli
    echo "Download URL for ibmcloud CLI : https://download.clis.cloud.ibm.com/ibm-cloud-cli/${IC_CLI_VERSION}/IBM_Cloud_CLI_${IC_CLI_VERSION}_amd64.tar.gz"
    curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/${IC_CLI_VERSION}/IBM_Cloud_CLI_${IC_CLI_VERSION}_amd64.tar.gz
    tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
    mv /tmp/ibm_cloud_cli/Bluemix_CLI/bin/ibmcloud $HOME/.tmp/bin
    set +e
else
    echo -e "\nibmcloud CLI is already installed with below version, Skipping installation."
fi
ibmcloud --version

# Install IBM Cloud plugins
plugins_list=("vpc-infrastructure" "cloud-dns-services")
echo -e "\nInstalling the required IBM Cloud CLI plugins if not present."
for plugin in "${plugins_list[@]}"; do
    if ! ibmcloud plugin list | grep "$plugin"; then
        echo "$plugin plugin is not installed. Installing it now..."
        ibmcloud plugin install "$plugin" -f
        echo "$plugin plugin installed successfully."
    else
        echo "$plugin plugin is already installed."
    fi
done

IC_API_KEY=$(cat "${AGENT_IBMZ_CREDENTIALS}/ibmcloud-apikey")
export IC_API_KEY

# Login to IBM cloud
echo "Logging in to IBM Cloud..."
ibmcloud login --apikey "$IC_API_KEY" -r "$IC_REGION" -g "$RESOURCE_GROUP" || { echo "Login failed"; exit 1; }
echo "Login successful."

# To get the bastion node IP
bastion_ip=$(ibmcloud is instances --json \
  | jq -r --arg CN "$CLUSTER_NAME" \
    '.[] | select(.name | test($CN + ".*bastion")) 
         | .primary_network_interface.primary_ip.address')
    
echo "Bastion IP: $bastion_ip"

# Get cluster nodes (control + compute)
echo "Fetching cluster nodes..."

nodes=$(ibmcloud is instances --json \
  | jq -r --arg CN "$CLUSTER_NAME" \
      '.[] 
       | select(.name | test($CN + ".*(control|compute)")) 
       | "\(.name) \(.primary_network_interface.primary_ip.address)"')

echo "Nodes found:"
echo "$nodes"

# Determine Compact vs HA cluster
node_count=$(echo "$nodes" | wc -l | tr -d ' ')
compute_count=$(echo "$nodes" | grep -c "compute" || true)

echo "Node Count: $node_count"
echo "Compute Node Count: $compute_count"

if [[ "$node_count" -eq 3 && "$compute_count" -eq 0 ]]; then
    cluster_type="compact"
elif [[ "$node_count" -ge 3 && "$compute_count" -gt 0 ]]; then
    cluster_type="ha"
else
    echo "ERROR: Unknown cluster type or unexpected node layout."
    exit 1
fi

echo "Cluster Type Detected: $cluster_type"

# Get IPs for HAProxy backend
echo "Fetching worker node IPs..."

if [[ "$cluster_type" == "compact" ]]; then
    worker_ips=$(echo "$nodes" | grep "control" | awk '{print $2}')
else
    worker_ips=$(echo "$nodes" | grep "compute" | awk '{print $2}')
fi

echo "Worker Node IPs:"
echo "$worker_ips"

# Get the floating IP of bastion node
BASTION_FIP=$(ibmcloud is instances \
  | awk -v CN="$CLUSTER_NAME" '$2 ~ CN && $2 ~ /bastion/ {print $5}')
echo "Bastion floating IP: $BASTION_FIP"

# Generate HAProxy frontend/backend section
haproxy_section="/tmp/haproxy-${CLUSTER_NAME}.cfg"
cat > "$haproxy_section" <<EOF
frontend hosted2-api-server
   mode tcp
   option tcplog
   bind ${bastion_ip}:30000-33000
   default_backend hosted2-api-server

backend hosted2-api-server
   mode tcp
   balance source
EOF

i=0
while read -r ip; do
    echo "   server hosted2-worker-$i $ip" >> "$haproxy_section"
    ((i++))
done <<< "$worker_ips"

echo "Generated HAProxy section:"
cat "$haproxy_section"

# Update HAProxy on bastion
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@"$BASTION_FIP" bash <<EOF
# Backup existing HAProxy config
cp $HAPROXY_REMOTE_CFG ${HAPROXY_REMOTE_CFG}.bak_\$(date +%F_%H%M%S)

# Remove old cluster section if exists
if grep -q 'hosted2-api-server' $HAPROXY_REMOTE_CFG; then
    sed -i '/hosted2-api-server/,/^$/d' $HAPROXY_REMOTE_CFG
fi

# Append new section
cat >> $HAPROXY_REMOTE_CFG <<HASECTION
$(cat "$haproxy_section")
HASECTION

# Restart HAProxy
systemctl restart haproxy
systemctl status haproxy --no-pager
EOF

echo "✔ HAProxy updated successfully on bastion $BASTION_FIP"

# Download hosted cluster kubeconfig
echo "$(date) Create hosted cluster kubeconfig"
${HYPERSHIFT_CLI_NAME} create kubeconfig kubevirt --namespace=${HC_NS} --name=${HC_NAME} >${SHARED_DIR}/nested_kubeconfig
echo "${HC_NAME}" > "${SHARED_DIR}/cluster-name"

# Get NodePort
NODEPORT=$(oc get svc kube-apiserver -n $HC_NS -o jsonpath='{.spec.ports[?(@.port==6443)].nodePort}')
echo "Kube-apiserver NodePort: $NODEPORT"

# Update kubeconfig server URL
sed -i "s#server: https://.*:6443#server: https://${BASTION_FIP}:${NODEPORT}#g" ${SHARED_DIR}/nested_kubeconfig

# Get the HTTP & HTTPS node port
HOSTED_KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
HTTP_NODEPORT=$(oc --kubeconfig "$HOSTED_KUBECONFIG" \
  get svc router-nodeport-default -n openshift-ingress \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
echo "HTTP NodePort: $HTTP_NODEPORT"

HTTPS_NODEPORT=$(oc --kubeconfig "$HOSTED_KUBECONFIG" \
  get svc router-nodeport-default -n openshift-ingress \
  -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
echo "HTTPS NodePort: $HTTPS_NODEPORT"

# Create loadbalancer service
oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  labels:
    app: $HC_NAME
  name: ${hcp_ns}-apps
  namespace: $hcp_ns
spec:
  ports:
  - name: https-443
    port: 443
    protocol: TCP
    targetPort: $HTTPS_NODEPORT
  - name: http-80
    port: 80
    protocol: TCP
    targetPort: $HTTP_NODEPORT
  selector:
    kubevirt.io: virt-launcher
  type: LoadBalancer
EOF

#-------------------------------------
# Configure a DNS A record in IBM cloud
#------------------------------------- 
LB_SVC_NAME="${hcp_ns}-apps"
DNS_ZONE_NAME="${HC_NAME}.${hcp_domain}"
DNS_INSTANCE_NAME="${CLUSTER_NAME}-dns"
TTL=3600

echo "Fetching LoadBalancer external IP for $LB_SVC_NAME..."
LB_EXTERNAL_IP=$(oc get svc "$LB_SVC_NAME" -n "$hcp_ns" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

# Wait until LB external IP is available
while [[ -z "$LB_EXTERNAL_IP" || "$LB_EXTERNAL_IP" == "<pending>" ]]; do
    echo "LoadBalancer external IP not ready yet, waiting 5s..."
    sleep 5
    LB_EXTERNAL_IP=$(oc get svc "$LB_SVC_NAME" -n "$hcp_ns" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
done
echo "LoadBalancer External IP: $LB_EXTERNAL_IP"
echo

echo "=== Creating DNS Zone: ${DNS_ZONE_NAME} ==="
ZONE_OUTPUT=$(ibmcloud dns zone-create --instance "$DNS_INSTANCE_NAME" "$DNS_ZONE_NAME")
echo "$ZONE_OUTPUT"
echo

ZONE_ID=$(echo "$ZONE_OUTPUT" | awk '/ID/ {print $2}')
echo "DNS Zone ID: $ZONE_ID"
echo

echo "=== Getting VPC CRN ==="
VPC_NAME="${CLUSTER_NAME}-vpc"
VPC_CRN=$(ibmcloud is vpc "$VPC_NAME" --json | jq -r '.crn')

if [[ -z "$VPC_CRN" || "$VPC_CRN" == "null" ]]; then
    echo "ERROR: VPC '$VPC_NAME' not found!"
    exit 1
fi

echo "VPC CRN: $VPC_CRN"

echo "=== Adding Permitted Network to DNS Zone ==="
ibmcloud dns permitted-network-add "$ZONE_ID" \
    --vpc-crn "$VPC_CRN" \
    --instance "$DNS_INSTANCE_NAME"

echo
echo "=== Verifying DNS Zone ==="
ibmcloud dns zones --instance "$DNS_INSTANCE_NAME"
echo

echo "=== Creating Wildcard A Record: *.apps.${DNS_ZONE_NAME} ==="
ibmcloud dns resource-record-create "$ZONE_ID" \
  --type A \
  --name '*.apps' \
  --ipv4 "$LB_EXTERNAL_IP" \
  --ttl "$TTL" \
  --instance "$DNS_INSTANCE_NAME"

echo
echo "=== DNS Setup Complete ==="
echo "*.apps.${DNS_ZONE_NAME}  -->  ${LB_EXTERNAL_IP}"

# Verifying the Hosted Cluster status
echo "$(date) Checking the Hosted Cluster status"
oc get no --kubeconfig="${SHARED_DIR}/nested_kubeconfig"
oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" wait --all=true co --for=condition=Available=True --timeout=30m

echo "$(date) Successfully completed the Hosted cluster creation with type Kubevirt"





