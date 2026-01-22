#!/bin/bash

set -x
set -e

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

job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export job_id
export CLUSTER_NAME="hcp-s390x-mgmt-ci-$job_id"
SSH_KEY="$SHARED_DIR/$CLUSTER_NAME-key"
chmod 600 $SSH_KEY
HAPROXY_REMOTE_CFG="/etc/haproxy/haproxy.cfg"

ssh_key_string=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-key")
export ssh_key_string
tmp_ssh_key="/tmp/ssh-private-key"
envsubst <<"EOF" >${tmp_ssh_key}
-----BEGIN OPENSSH PRIVATE KEY-----
${ssh_key_string}
-----END OPENSSH PRIVATE KEY-----
EOF
chmod 0600 ${tmp_ssh_key}

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

# Remove default from virtualization SC for odf and set cepg-rbd as default sc
oc annotate --overwrite sc ocs-storagecluster-ceph-rbd-virtualization \
  storageclass.kubernetes.io/is-default-class='false'

oc annotate --overwrite sc ocs-storagecluster-ceph-rbd \
  storageclass.kubernetes.io/is-default-class='true'

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

# Install IBM Cloud CLI
export PATH="$HOME/.tmp/bin:$PATH"
mkdir -p "$HOME/.tmp/bin"

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

# shellcheck disable=SC2087
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@"$BASTION_FIP" bash << EOF
cp "$HAPROXY_REMOTE_CFG" "${HAPROXY_REMOTE_CFG}.bak_$(date +%F_%H%M%S)"
sed -i '/hosted2-api-server/,/^$/d' "$HAPROXY_REMOTE_CFG"
EOF

# shellcheck disable=SC2087
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@"$BASTION_FIP" \
  "cat >> \"$HAPROXY_REMOTE_CFG\"" << EOF2
$(cat "$haproxy_section")
EOF2

#Restart HAProxy
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no root@"$BASTION_FIP" bash << EOF
systemctl restart haproxy
systemctl status haproxy --no-pager
EOF

echo "HAProxy updated successfully on bastion $BASTION_FIP"

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
sg_name="$CLUSTER_NAME-sg"
create_sg_rule $sg_name inbound tcp 30000 33000


echo "$(date) Create hosted cluster kubeconfig"
${HYPERSHIFT_CLI_NAME} create kubeconfig kubevirt \
  --namespace="${HC_NS}" --name="${HC_NAME}" \
  > "${SHARED_DIR}/nested_kubeconfig"
echo "${HC_NAME}" > "${SHARED_DIR}/cluster-name"

HOSTED_KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

# --- Wait for kube-apiserver NodePort ---
echo "Waiting for kube-apiserver service..."
NODEPORT=""
for i in {1..30}; do
  NODEPORT=$(oc get svc kube-apiserver -n "${HC_NS}-${HC_NAME}" \
    -o jsonpath="{.spec.ports[?(@.port==6443)].nodePort}" 2>/dev/null || true)
  if [[ -n "$NODEPORT" ]]; then
    break
  fi
  echo "kube-apiserver NodePort not ready yet, retrying... ($i/30)"
  sleep 10
done

if [[ -z "$NODEPORT" ]]; then
  echo "ERROR: kube-apiserver service not found"
  exit 1
fi
echo "Kube-apiserver NodePort: $NODEPORT"

# --- Update kubeconfig server URL safely ---
CLSTR_NAME=$(oc --kubeconfig "$HOSTED_KUBECONFIG" config view -o jsonpath='{.clusters[0].name}')
oc --kubeconfig "$HOSTED_KUBECONFIG" config set-cluster "$CLSTR_NAME" \
  --server="https://${BASTION_FIP}:${NODEPORT}"
echo "Updated kubeconfig server URL to https://${BASTION_FIP}:${NODEPORT}"

#Wait for Hosted control plane pods to come up
RETRIES=40
INTERVAL=30  # seconds

for i in $(seq 1 "$RETRIES") max; do
  [[ "$i" == "max" ]] && break

  DESIRED_NODES=$(oc get np "$HC_NAME" -n "$HC_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
  CURRENT_NODES=$(oc get np "$HC_NAME" -n "$HC_NS" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")

  if [[ -z "$DESIRED_NODES" || -z "$CURRENT_NODES" ]]; then
    echo "[Retry $i/$RETRIES] NodePool $HC_NAME not found yet. Retrying in $INTERVAL seconds..."
    sleep $INTERVAL
    continue
  fi

  if [[ "$DESIRED_NODES" == "$CURRENT_NODES" ]]; then
    echo "NodePool $HC_NAME is ready: $CURRENT_NODES/$DESIRED_NODES nodes"
    break
  fi

  echo "[Retry $i/$RETRIES] NodePool not ready: desired=$DESIRED_NODES, current=$CURRENT_NODES. Retrying in $INTERVAL seconds..."
  sleep $INTERVAL
done

# Final check after retries
DESIRED_NODES=$(oc get np "$HC_NAME" -n "$HC_NS" -o jsonpath='{.spec.replicas}')
CURRENT_NODES=$(oc get np "$HC_NAME" -n "$HC_NS" -o jsonpath='{.status.replicas}')

if [[ "$DESIRED_NODES" != "$CURRENT_NODES" ]]; then
  echo "Timeout waiting for NodePool $HC_NAME: desired=$DESIRED_NODES, current=$CURRENT_NODES"
  exit 1
fi

echo "Fetching router-nodeport-default service NodePorts..."

HTTP_NODEPORT=$(oc get svc router-nodeport-default \
  -n openshift-ingress \
  --kubeconfig "$HOSTED_KUBECONFIG" \
  --insecure-skip-tls-verify \
  -o jsonpath="{.spec.ports[?(@.name=='http')].nodePort}")

HTTPS_NODEPORT=$(oc get svc router-nodeport-default \
  -n openshift-ingress \
  --kubeconfig "$HOSTED_KUBECONFIG" \
  --insecure-skip-tls-verify \
  -o jsonpath="{.spec.ports[?(@.name=='https')].nodePort}")

echo "HTTP NodePort:  $HTTP_NODEPORT"
echo "HTTPS NodePort: $HTTPS_NODEPORT"

if [[ -z "$HTTP_NODEPORT" || -z "$HTTPS_NODEPORT" ]]; then
  echo "ERROR: NodePorts not assigned"
  exit 1
fi

# --- Export for next Prow steps ---
export HOSTED_KUBECONFIG
export HTTP_NODEPORT
export HTTPS_NODEPORT

echo "Hosted kubeconfig and NodePorts are ready."

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

if oc wait node --all \
    --for=condition=Ready \
    --timeout=5m \
    --kubeconfig="${SHARED_DIR}/nested_kubeconfig" \
    --insecure-skip-tls-verify; then

    echo "All nodes are Ready"

else
    echo "Some nodes failed to become Ready"
    oc get nodes --kubeconfig="${SHARED_DIR}/nested_kubeconfig" --insecure-skip-tls-verify -o wide
    exit 1
fi

echo "$(date) Successfully completed the Hosted cluster creation with type Kubevirt"







