#!/bin/bash
#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM
#Save stacks events
# trap 'save_stack_events_to_artifacts' EXIT TERM INT

export OCI_CLI_CONFIG_FILE=/var/run/vault/opct-splat/opct-oci-splat-user-config
function upi_conf_provider() {
  mkdir -p $HOME/.oci
  ln -svf $OCI_CLI_CONFIG_FILE $HOME/.oci/config
  # Clients
  echo_date "Installing oci-cli"
  python3.9 -m venv /tmp/venv-oci && source /tmp/venv-oci/bin/activate
  pip install oci-cli > /dev/null
}

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

function save_resource_env() {
  echo "$1=$2" >> ${SHARED_DIR}/infra_resources.env
}

export PATH=/tmp:${PATH}

echo "======================="
echo "Installing dependencies"
echo "======================="

echo_date "Installing provider's client"
upi_conf_provider

echo_date "Installing yq"
wget -qO /tmp/yq "https://github.com/mikefarah/yq/releases/download/v4.34.1/yq_linux_amd64"
chmod u+x /tmp/yq

echo_date "Installing butane"
wget -qO /tmp/butane "https://github.com/coreos/butane/releases/download/v0.18.0/butane-x86_64-unknown-linux-gnu"
chmod u+x /tmp/butane

echo_date "Checking/installing yq3..."
if ! [ -x "$(command -v yq3)" ]; then
  wget -qO /tmp/yq3 https://github.com/mikefarah/yq/releases/download/3.4.0/yq_linux_amd64
  chmod u+x /tmp/yq3
fi
which yq3

echo "==============="
echo "Export Defaults"
echo "==============="

source /var/run/vault/opct-splat/opct-runner-vars-compartments

# A new compartment will be created as a child of this:
PARENT_COMPARTMENT_ID="${OCI_COMPARTMENT_ID}"
# DNS information
DNS_COMPARTMENT_ID="${OCI_COMPARTMENT_ID_DNS}"

INSTALL_DIR=$SHARED_DIR

BASE_DOMAIN=$(yq ea '.baseDomain' "${SHARED_DIR}/install-config.yaml")
CLUSTER_NAME=$(yq ea '.metadata.name' "${SHARED_DIR}/install-config.yaml")

save_resource_env "CLUSTER_NAME" "${CLUSTER_NAME}"

export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
#oci setup repair-file-permissions --file /var/run/vault/opct-splat/opct-oci-splat-user-config

echo "===================================="
echo "CREATING INFRASTRUCTURE DEPENDENCIES"

echo "==================="
echo "CREATING STACK: IAM"
echo "==================="

echo_date "[IAM] Creating Compartment"

COMPARTMENT_NAME_OPENSHIFT="$CLUSTER_NAME"
COMPARTMENT_ID_OPENSHIFT=$(oci iam compartment create \
  --compartment-id "$PARENT_COMPARTMENT_ID" \
  --description "$COMPARTMENT_NAME_OPENSHIFT compartment" \
  --name "$COMPARTMENT_NAME_OPENSHIFT" \
  --wait-for-state ACTIVE \
  --query data.id --raw-output)

save_resource_env "COMPARTMENT_ID_OPENSHIFT" "${COMPARTMENT_ID_OPENSHIFT}"

echo_date "[IAM] Compartment created!"
echo_date "[IAM] Creating tag-namespace"

TAG_NAMESPACE_ID=$(oci iam tag-namespace create \
  --compartment-id "${COMPARTMENT_ID_OPENSHIFT}" \
  --description "Cluster Name" \
  --name "$CLUSTER_NAME" \
  --wait-for-state ACTIVE \
  --query data.id --raw-output)

save_resource_env "TAG_NAMESPACE_ID" "${TAG_NAMESPACE_ID}"

echo_date "[IAM] Creating tag"

oci iam tag create \
  --description "OpenShift Node Role" \
  --name "role" \
  --tag-namespace-id "$TAG_NAMESPACE_ID" \
  --validator '{"validatorType":"ENUM","values":["master","worker"]}'

DYNAMIC_GROUP_NAME="${CLUSTER_NAME}-controlplane"

echo_date "[IAM] Creating dynamic group"
oci iam dynamic-group create \
  --name "${DYNAMIC_GROUP_NAME}" \
  --description "Control Plane nodes for ${CLUSTER_NAME}" \
  --matching-rule "Any {instance.compartment.id='$COMPARTMENT_ID_OPENSHIFT', tag.${CLUSTER_NAME}.role.value='master'}" \
  --wait-for-state ACTIVE

save_resource_env "DYNAMIC_GROUP_NAME" "${DYNAMIC_GROUP_NAME}"

echo_date "[IAM] Creating policy"
POLICY_NAME="${CLUSTER_NAME}-cloud-controller-manager"
oci iam policy create --name $POLICY_NAME \
    --compartment-id $COMPARTMENT_ID_OPENSHIFT \
    --description "Allow Cloud Controller Manager in OpenShift access Cloud Resources" \
    --statements "[
\"Allow dynamic-group $DYNAMIC_GROUP_NAME to manage volume-family in compartment $COMPARTMENT_NAME_OPENSHIFT\",
\"Allow dynamic-group $DYNAMIC_GROUP_NAME to manage instance-family in compartment $COMPARTMENT_NAME_OPENSHIFT\",
\"Allow dynamic-group $DYNAMIC_GROUP_NAME to manage security-lists in compartment $COMPARTMENT_NAME_OPENSHIFT\",
\"Allow dynamic-group $DYNAMIC_GROUP_NAME to use virtual-network-family in compartment $COMPARTMENT_NAME_OPENSHIFT\",
\"Allow dynamic-group $DYNAMIC_GROUP_NAME to manage load-balancers in compartment $COMPARTMENT_NAME_OPENSHIFT\"]"

save_resource_env "POLICY_NAME" "${POLICY_NAME}"

echo "========================"
echo "CREATING STACK: NETWORK"
echo "========================"

# Base doc for network service
# https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.30.2/oci_cli_docs/cmdref/network.html

echo_date "[Network] Creating VCN"
# VCN
## https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.30.2/oci_cli_docs/cmdref/network/vcn/create.html
VCN_ID=$(oci network vcn create \
  --compartment-id "${COMPARTMENT_ID_OPENSHIFT}" \
  --display-name "${CLUSTER_NAME}-vcn" \
  --cidr-block "10.0.0.0/20" \
  --dns-label "ocp" \
  --wait-for-state AVAILABLE \
  --query data.id --raw-output)

save_resource_env "VCN_ID" "${VCN_ID}"

echo_date "[Network] Creating IGW"
# IGW
## https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.30.2/oci_cli_docs/cmdref/network/internet-gateway/create.html
IGW_ID=$(oci network internet-gateway create \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --display-name "${CLUSTER_NAME}-igw" \
  --is-enabled true \
  --wait-for-state AVAILABLE \
  --vcn-id $VCN_ID \
  --query data.id --raw-output)

echo_date "[Network] Creating NAT Gateway"
# NAT Gateway
## https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.30.2/oci_cli_docs/cmdref/network/nat-gateway/create.html
NGW_ID=$(oci network nat-gateway create \
  --compartment-id ${COMPARTMENT_ID_OPENSHIFT} \
  --display-name "${CLUSTER_NAME}-natgw" \
  --vcn-id $VCN_ID \
  --wait-for-state AVAILABLE \
  --query data.id --raw-output)

echo_date "[Network] Creating Route Table: Public"
# Route Table: Public
## https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.30.2/oci_cli_docs/cmdref/network/route-table/create.html
RTB_PUB_ID=$(oci network route-table create \
  --compartment-id ${COMPARTMENT_ID_OPENSHIFT} \
  --vcn-id $VCN_ID \
  --display-name "${CLUSTER_NAME}-rtb-public" \
  --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"$IGW_ID\"}]" \
  --wait-for-state AVAILABLE \
  --query data.id --raw-output)

echo_date "[Network] Creating Route Table: Private"
# Route Table: Private
RTB_PVT_ID=$(oci network route-table create \
  --compartment-id ${COMPARTMENT_ID_OPENSHIFT} \
  --vcn-id $VCN_ID \
  --display-name "${CLUSTER_NAME}-rtb-private" \
  --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"$NGW_ID\"}]" \
  --wait-for-state AVAILABLE \
  --query data.id --raw-output)

# Subnet Public (regional)
# https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.30.2/oci_cli_docs/cmdref/network/subnet/create.html
echo_date "[Network] Creating regional subnet: public"
SUBNET_ID_PUBLIC=$(oci network subnet create \
  --compartment-id ${COMPARTMENT_ID_OPENSHIFT} \
  --vcn-id $VCN_ID \
  --display-name "${CLUSTER_NAME}-net-public" \
  --dns-label "pub" \
  --cidr-block "10.0.0.0/21" \
  --route-table-id $RTB_PUB_ID \
  --wait-for-state AVAILABLE \
  --query data.id --raw-output)

# Subnet Private (regional)
echo_date "[Network] Creating regional subnet: private"
SUBNET_ID_PRIVATE=$(oci network subnet create \
  --compartment-id ${COMPARTMENT_ID_OPENSHIFT} \
  --vcn-id $VCN_ID \
  --display-name "${CLUSTER_NAME}-net-private" \
  --dns-label "priv" \
  --cidr-block "10.0.8.0/21" \
  --route-table-id $RTB_PVT_ID \
  --prohibit-internet-ingress true \
  --prohibit-public-ip-on-vnic true \
  --wait-for-state AVAILABLE \
  --query data.id --raw-output)


# NSGs (empty to allow be referenced in the rules)
## NSG Control Plane
## https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.30.2/oci_cli_docs/cmdref/network/nsg/create.html
echo_date "[Network] Creating NSG Control Plane"
NSG_ID_CPL=$(oci network nsg create \
  --compartment-id ${COMPARTMENT_ID_OPENSHIFT} \
  --vcn-id $VCN_ID \
  --display-name "${CLUSTER_NAME}-nsg-controlplane" \
  --wait-for-state AVAILABLE \
  --query data.id --raw-output)

## NSG Compute/workers
echo_date "[Network] Creating NSG Compute"
NSG_ID_CMP=$(oci network nsg create \
  --compartment-id ${COMPARTMENT_ID_OPENSHIFT} \
  --vcn-id $VCN_ID \
  --display-name "${CLUSTER_NAME}-nsg-compute" \
  --wait-for-state AVAILABLE \
  --query data.id --raw-output)

## NSG Load Balancers
echo_date "[Network] Creating NSG LB"
NSG_ID_NLB=$(oci network nsg create \
  --compartment-id ${COMPARTMENT_ID_OPENSHIFT} \
  --vcn-id $VCN_ID \
  --display-name "${CLUSTER_NAME}-nsg-nlb" \
  --wait-for-state AVAILABLE \
  --query data.id --raw-output)

# NSG Rules: Control Plane NSG
## https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.30.2/oci_cli_docs/cmdref/network/nsg/rules/add.html
# oci network NSG rules add --generate-param-json-input security-rules
cat <<EOF > ./oci-vcn-nsg-rule-nodes.json
[
  {
    "description": "allow all outbound traffic",
    "protocol": "all", "destination": "0.0.0.0/0", "destination-type": "CIDR_BLOCK",
    "direction": "EGRESS", "is-stateless": false
  },
  {
    "description": "All from control plane NSG",
    "direction": "INGRESS", "is-stateless": false,
    "protocol": "all",
    "source": "$NSG_ID_CPL", "source-type": "NETWORK_SECURITY_GROUP"
  },
  {
    "description": "All from control plane NSG",
    "direction": "INGRESS", "is-stateless": false,
    "protocol": "all",
    "source": "$NSG_ID_CMP", "source-type": "NETWORK_SECURITY_GROUP"
  },
  {
    "description": "All from control plane NSG",
    "direction": "INGRESS", "is-stateless": false,
    "protocol": "all",
    "source": "$NSG_ID_NLB", "source-type": "NETWORK_SECURITY_GROUP"
  },
  {
    "description": "allow ssh to nodes",
    "direction": "INGRESS", "is-stateless": false,
    "protocol": "6",
    "source": "0.0.0.0/0", "source-type": "CIDR_BLOCK",
    "tcp-options": {
      "destination-port-range": {
        "max": 22,
        "min": 22
      }
    }
  }
]
EOF

echo_date "[Network] Updating NSG Rules"
oci network nsg rules add \
  --nsg-id "${NSG_ID_CPL}" \
  --security-rules file://oci-vcn-nsg-rule-nodes.json

oci network nsg rules add \
  --nsg-id "${NSG_ID_CMP}" \
  --security-rules file://oci-vcn-nsg-rule-nodes.json

# NSG Security rules for NSG
cat <<EOF > ./oci-vcn-nsg-rule-nlb.json
[
  {
    "description": "allow Kube API",
    "direction": "INGRESS", "is-stateless": false,
    "source-type": "CIDR_BLOCK", "protocol": "6", "source": "0.0.0.0/0",
    "tcp-options": { "destination-port-range": {
      "max": 6443, "min": 6443
    }}
  },
  {
    "description": "allow Kube API to Control Plane",
    "destination": "$NSG_ID_CPL",
    "destination-type": "NETWORK_SECURITY_GROUP",
    "direction": "EGRESS", "is-stateless": false,
    "protocol": "6", "tcp-options":{"destination-port-range":{
      "max": 6443, "min": 6443
    }}
  },
  {
    "description": "allow MCS listener from control plane pool",
    "direction": "INGRESS",
    "is-stateless": false, "protocol": "6",
    "source": "$NSG_ID_CPL", "source-type": "NETWORK_SECURITY_GROUP",
    "tcp-options": {"destination-port-range":{
      "max": 22623, "min": 22623
    }}
  },
  {
    "description": "allow MCS listener from compute pool",
    "direction": "INGRESS",
    "is-stateless": false, "protocol": "6",
    "source": "$NSG_ID_CMP", "source-type": "NETWORK_SECURITY_GROUP",
    "tcp-options": {"destination-port-range": {
      "max": 22623, "min": 22623
    }}
  },
  {
    "description": "allow MCS listener access the Control Plane backends",
    "destination": "$NSG_ID_CPL",
    "destination-type": "NETWORK_SECURITY_GROUP",
    "direction": "EGRESS", "is-stateless": false,
    "protocol": "6", "tcp-options": {"destination-port-range": {
      "max": 22623, "min": 22623
    }}
  },
  {
    "description": "allow listener for Ingress HTTP",
    "direction": "INGRESS", "is-stateless": false,
    "source-type": "CIDR_BLOCK", "protocol": "6", "source": "0.0.0.0/0",
    "tcp-options": {"destination-port-range": {
      "max": 80, "min": 80
    }}
  },
  {
    "description": "allow listener for Ingress HTTPS",
    "direction": "INGRESS", "is-stateless": false,
    "source-type": "CIDR_BLOCK", "protocol": "6", "source": "0.0.0.0/0",
    "tcp-options": {"destination-port-range": {
      "max": 443, "min": 443
    }}
  },
  {
    "description": "allow backend access the Compute pool for HTTP",
    "destination": "$NSG_ID_CMP",
    "destination-type": "NETWORK_SECURITY_GROUP",
    "direction": "EGRESS", "is-stateless": false,
    "protocol": "6", "tcp-options": {"destination-port-range": {
      "max": 80, "min": 80
    }}
  },
  {
    "description": "allow backend access the Compute pool for HTTPS",
    "destination": "$NSG_ID_CMP",
    "destination-type": "NETWORK_SECURITY_GROUP",
    "direction": "EGRESS", "is-stateless": false,
    "protocol": "6", "tcp-options": {"destination-port-range": {
      "max": 443, "min": 443
    }}
  }
]
EOF

oci network nsg rules add \
  --nsg-id "${NSG_ID_NLB}" \
  --security-rules file://oci-vcn-nsg-rule-nlb.json


echo "============================="
echo "CREATING STACK: Load Balancer"
echo "============================="

# NLB base: https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.30.2/oci_cli_docs/cmdref/nlb.html

# Create BackendSets
## Kubernetes API Server (KAS): api
## Machine Config Server (MCS): mcs
## Ingress HTTP
## Ingress HTTPS
cat <<EOF > ./oci-nlb-backends.json
{
  "${CLUSTER_NAME}-api": {
    "health-checker": {
      "interval-in-millis": 10000,
      "port": 6443,
      "protocol": "HTTPS",
      "retries": 3,
      "return-code": 200,
      "timeout-in-millis": 3000,
      "url-path": "/readyz"
    },
    "ip-version": "IPV4",
    "is-preserve-source": false,
    "name": "${CLUSTER_NAME}-api",
    "policy": "FIVE_TUPLE"
  },
  "${CLUSTER_NAME}-mcs": {
    "health-checker": {
      "interval-in-millis": 10000,
      "port": 22623,
      "protocol": "HTTPS",
      "retries": 3,
      "return-code": 200,
      "timeout-in-millis": 3000,
      "url-path": "/healthz"
    },
    "ip-version": "IPV4",
    "is-preserve-source": false,
    "name": "${CLUSTER_NAME}-mcs",
    "policy": "FIVE_TUPLE"
  },
  "${CLUSTER_NAME}-ingress-http": {
    "health-checker": {
      "interval-in-millis": 10000,
      "port": 80,
      "protocol": "TCP",
      "retries": 3,
      "timeout-in-millis": 3000
    },
    "ip-version": "IPV4",
    "is-preserve-source": false,
    "name": "${CLUSTER_NAME}-ingress-http",
    "policy": "FIVE_TUPLE"
  },
  "${CLUSTER_NAME}-ingress-https": {
    "health-checker": {
      "interval-in-millis": 10000,
      "port": 443,
      "protocol": "TCP",
      "retries": 3,
      "timeout-in-millis": 3000
    },
    "ip-version": "IPV4",
    "is-preserve-source": false,
    "name": "${CLUSTER_NAME}-ingress-https",
    "policy": "FIVE_TUPLE"
  }
}
EOF

cat <<EOF > ./oci-nlb-listeners.json
{
  "${CLUSTER_NAME}-api": {
    "default-backend-set-name": "${CLUSTER_NAME}-api",
    "ip-version": "IPV4",
    "name": "${CLUSTER_NAME}-api",
    "port": 6443,
    "protocol": "TCP"
  },
  "${CLUSTER_NAME}-mcs": {
    "default-backend-set-name": "${CLUSTER_NAME}-mcs",
    "ip-version": "IPV4",
    "name": "${CLUSTER_NAME}-mcs",
    "port": 22623,
    "protocol": "TCP"
  },
  "${CLUSTER_NAME}-ingress-http": {
    "default-backend-set-name": "${CLUSTER_NAME}-ingress-http",
    "ip-version": "IPV4",
    "name": "${CLUSTER_NAME}-ingress-http",
    "port": 80,
    "protocol": "TCP"
  },
  "${CLUSTER_NAME}-ingress-https": {
    "default-backend-set-name": "${CLUSTER_NAME}-ingress-https",
    "ip-version": "IPV4",
    "name": "${CLUSTER_NAME}-ingress-https",
    "port": 443,
    "protocol": "TCP"
  }
}
EOF

# NLB create
# https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.30.2/oci_cli_docs/cmdref/nlb/network-load-balancer/create.html
NLB_ID=$(oci nlb network-load-balancer create \
  --compartment-id ${COMPARTMENT_ID_OPENSHIFT} \
  --display-name "${CLUSTER_NAME}-nlb" \
  --subnet-id "${SUBNET_ID_PUBLIC}" \
  --backend-sets file://oci-nlb-backends.json \
  --listeners file://oci-nlb-listeners.json \
  --network-security-group-ids "[\"$NSG_ID_NLB\"]" \
  --is-private false \
  --nlb-ip-version "IPV4" \
  --wait-for-state ACCEPTED \
  --query data.id --raw-output)

save_resource_env "NLB_ID" "${NLB_ID}"

echo "==================="
echo "CREATING STACK: DNS"
echo "==================="

# NLB IPs
## https://docs.oracle.com/en-us/iaas/tools/oci-cli/3.30.2/oci_cli_docs/cmdref/nlb/network-load-balancer/list.html
## Public
NLB_IP_PUBLIC=$(oci nlb network-load-balancer list \
  --compartment-id ${COMPARTMENT_ID_OPENSHIFT} \
  --display-name "${CLUSTER_NAME}-nlb" \
  | jq -r '.data.items[0]["ip-addresses"][] | select(.["is-public"]==true) | .["ip-address"]')

## Private
NLB_IP_PRIVATE=$(oci nlb network-load-balancer list \
  --compartment-id ${COMPARTMENT_ID_OPENSHIFT} \
  --display-name "${CLUSTER_NAME}-nlb" \
  | jq -r '.data.items[0]["ip-addresses"][] | select(.["is-public"]==false) | .["ip-address"]')

# DNS record
## Assuming the zone already exists and is in DNS_COMPARTMENT_ID
DNS_RECORD_APIINT="api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"
oci dns record rrset patch \
  --compartment-id ${DNS_COMPARTMENT_ID} \
  --domain "${DNS_RECORD_APIINT}" \
  --rtype "A" \
  --zone-name-or-id "${BASE_DOMAIN}" \
  --scope GLOBAL \
  --items "[{
    \"domain\": \"${DNS_RECORD_APIINT}\",
    \"rdata\": \"${NLB_IP_PRIVATE}\",
    \"rtype\": \"A\", \"ttl\": 300
  }]"

DNS_RECORD_APIEXT="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
oci dns record rrset patch \
  --compartment-id ${DNS_COMPARTMENT_ID} \
  --domain "${DNS_RECORD_APIEXT}" \
  --rtype "A" \
  --zone-name-or-id "${BASE_DOMAIN}" \
  --scope GLOBAL \
  --items "[{
    \"domain\": \"${DNS_RECORD_APIEXT}\",
    \"rdata\": \"${NLB_IP_PUBLIC}\",
    \"rtype\": \"A\", \"ttl\": 300
  }]"

DNS_RECORD_APPS="*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
oci dns record rrset patch \
  --compartment-id ${DNS_COMPARTMENT_ID} \
  --domain "${DNS_RECORD_APPS}" \
  --rtype "A" \
  --zone-name-or-id "${BASE_DOMAIN}" \
  --scope GLOBAL \
  --items "[{
    \"domain\": \"${DNS_RECORD_APPS}\",
    \"rdata\": \"${NLB_IP_PUBLIC}\",
    \"rtype\": \"A\", \"ttl\": 300
  }]"


echo "==============================="
echo "CREATING STACK: COMPUTE / IMAGE"
echo "==============================="

IMAGE_NAME=$(basename "$(openshift-install coreos print-stream-json | jq -r '.architectures["x86_64"].artifacts["openstack"].formats["qcow2.gz"].disk.location')")

wget -q "$(openshift-install coreos print-stream-json | jq -r '.architectures["x86_64"].artifacts["openstack"].formats["qcow2.gz"].disk.location')"

BUCKET_NAME="${CLUSTER_NAME}-infra"
oci os bucket create --name $BUCKET_NAME --compartment-id $COMPARTMENT_ID_OPENSHIFT
save_resource_env "BUCKET_NAME" "${BUCKET_NAME}"

oci os object put -bn $BUCKET_NAME --name images/${IMAGE_NAME} --file ${IMAGE_NAME}

STORAGE_NAMESPACE=$(oci os ns get | jq -r .data)
oci compute image import from-object -bn $BUCKET_NAME --name images/${IMAGE_NAME} \
    --compartment-id $COMPARTMENT_ID_OPENSHIFT -ns $STORAGE_NAMESPACE \
    --display-name ${IMAGE_NAME} --launch-mode "PARAVIRTUALIZED" \
    --source-image-type "QCOW2"

# Gather the Custom Compute image for RHCOS
IMAGE_ID=$(oci compute image list --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --display-name $IMAGE_NAME | jq -r '.data[0].id')

save_resource_env "IMAGE_ID" "${IMAGE_ID}"

echo "===================================="
echo "CREATING STACK: COMPUTE / BOOTSTRAP"
echo "===================================="

# Gather subnet IDs
SUBNET_ID_PUBLIC=$(oci network subnet list --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  | jq -r '.data[] | select(.["display-name"] | endswith("public")).id')

SUBNET_ID_PRIVATE=$(oci network subnet list --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  | jq -r '.data[] | select(.["display-name"] | endswith("private")).id')

# Gather the Network Security group for the control plane
NSG_ID_CPL=$(oci network nsg list -c $COMPARTMENT_ID_OPENSHIFT \
  | jq -r '.data[] | select(.["display-name"] | endswith("controlplane")).id')

NSG_ID_CMP=$(oci network nsg list -c $COMPARTMENT_ID_OPENSHIFT \
  | jq -r '.data[] | select(.["display-name"] | endswith("compute")).id')


### Ignition config

oci os object put -bn $BUCKET_NAME --name bootstrap-${CLUSTER_NAME}.ign \
    --file $INSTALL_DIR/bootstrap.ign


EXPIRES_TIME=$(date -d '+1 hour' --rfc-3339=seconds)
IGN_BOOTSTRAP_URL=$(oci os preauth-request create --name bootstrap-${CLUSTER_NAME} \
    -bn $BUCKET_NAME -on bootstrap-${CLUSTER_NAME}.ign \
    --access-type ObjectRead  --time-expires "$EXPIRES_TIME" \
    | jq -r '.data["full-path"]')


cat <<EOF > ./user-data-bootstrap.json
{
  "ignition": {
    "config": {
      "replace": {
        "source": "${IGN_BOOTSTRAP_URL}"
      }
    },
    "version": "3.1.0"
  }
}
EOF


### Launch
AVAILABILITY_DOMAIN="gzqB:US-ASHBURN-1-AD-1"
INSTANCE_SHAPE="VM.Standard.E4.Flex"

oci compute instance launch \
    --hostname-label "bootstrap" \
    --display-name "bootstrap" \
    --availability-domain "$AVAILABILITY_DOMAIN" \
    --fault-domain "FAULT-DOMAIN-1" \
    --compartment-id $COMPARTMENT_ID_OPENSHIFT \
    --subnet-id $SUBNET_ID_PUBLIC \
    --nsg-ids "[\"$NSG_ID_CPL\"]" \
    --shape "$INSTANCE_SHAPE" \
    --shape-config "{\"memoryInGBs\":16.0,\"ocpus\":8.0}" \
    --source-details "{\"bootVolumeSizeInGBs\":120,\"bootVolumeVpusPerGB\":60,\"imageId\":\"${IMAGE_ID}\",\"sourceType\":\"image\"}" \
    --agent-config '{"areAllPluginsDisabled": true}' \
    --assign-public-ip True \
    --user-data-file "./user-data-bootstrap.json" \
    --defined-tags "{\"$CLUSTER_NAME\":{\"role\":\"master\"}}"

BES_API_NAME=$(oci nlb backend-set list --network-load-balancer-id $NLB_ID | jq -r '.data.items[] | select(.name | endswith("api")).name')
BES_MCS_NAME=$(oci nlb backend-set list --network-load-balancer-id $NLB_ID | jq -r '.data.items[] | select(.name | endswith("mcs")).name')

INSTANCE_ID_BOOTSTRAP=$(oci compute instance list  -c $COMPARTMENT_ID_OPENSHIFT | jq -r '.data[] | select((.["display-name"]=="bootstrap") and (.["lifecycle-state"]=="RUNNING")).id')

until test -n $INSTANCE_ID_BOOTSTRAP; do
  INSTANCE_ID_BOOTSTRAP=$(oci compute instance list  -c $COMPARTMENT_ID_OPENSHIFT | jq -r '.data[] | select((.["display-name"]=="bootstrap") and (.["lifecycle-state"]=="RUNNING")).id')
  sleep 10
done

test -z $INSTANCE_ID_BOOTSTRAP && echo "ERR: Bootstrap Instance ID not found=[$INSTANCE_ID_BOOTSTRAP]. Try again."

save_resource_env "INSTANCE_ID_BOOTSTRAP" "${INSTANCE_ID_BOOTSTRAP}"

## Add to Load Balancer

# oci nlb backend-set update --generate-param-json-input backends
cat <<EOF > ./nlb-bset-backends-api.json
[
  {
    "isBackup": false,
    "isDrain": false,
    "isOffline": false,
    "name": "${INSTANCE_ID_BOOTSTRAP}:6443",
    "port": 6443,
    "targetId": "${INSTANCE_ID_BOOTSTRAP}"
  }
]
EOF

# Update API Backend Set
oci nlb backend-set update --force \
  --backend-set-name $BES_API_NAME \
  --network-load-balancer-id $NLB_ID \
  --backends file://nlb-bset-backends-api.json \
  --wait-for-state SUCCEEDED

cat <<EOF > ./nlb-bset-backends-mcs.json
[
  {
    "isBackup": false,
    "isDrain": false,
    "isOffline": false,
    "name": "${INSTANCE_ID_BOOTSTRAP}:22623",
    "port": 22623,
    "targetId": "${INSTANCE_ID_BOOTSTRAP}"
  }
]
EOF

oci nlb backend-set update --force \
  --backend-set-name $BES_MCS_NAME \
  --network-load-balancer-id $NLB_ID \
  --backends file://nlb-bset-backends-mcs.json \
  --wait-for-state SUCCEEDED


echo "============================="
echo "CREATING STACK: CONTROL PLANE"
echo "============================="

INSTANCE_CONFIG_CONTROLPLANE="${CLUSTER_NAME}-controlplane"
# To generate all the options:
# oci compute-management instance-configuration create --generate-param-json-input instance-details
cat <<EOF > ./instance-config-details-controlplanes.json
{
  "instanceType": "compute",
  "launchDetails": {
    "agentConfig": {"areAllPluginsDisabled": true},
    "compartmentId": "$COMPARTMENT_ID_OPENSHIFT",
    "createVnicDetails": {
      "assignPrivateDnsRecord": true,
      "assignPublicIp": false,
      "nsgIds": ["$NSG_ID_CPL"],
      "subnetId": "$SUBNET_ID_PRIVATE"
    },
    "definedTags": {
      "$CLUSTER_NAME": {
        "role": "master"
      }
    },
    "displayName": "${CLUSTER_NAME}-controlplane",
    "launchMode": "PARAVIRTUALIZED",
    "metadata": {"user_data": "$(base64 -w0 < $INSTALL_DIR/master.ign)"},
    "shape": "$INSTANCE_SHAPE",
    "shapeConfig": {"memoryInGBs":16.0,"ocpus":8.0},
    "sourceDetails": {"bootVolumeSizeInGBs":120,"bootVolumeVpusPerGB":60,"imageId":"${IMAGE_ID}","sourceType":"image"}
  }
}
EOF

oci compute-management instance-configuration create \
  --display-name "$INSTANCE_CONFIG_CONTROLPLANE" \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --instance-details file://instance-config-details-controlplanes.json

INSTANCE_POOL_CONTROLPLANE="${CLUSTER_NAME}-controlplane"
INSTANCE_CONFIG_ID_CPL=$(oci compute-management instance-configuration list \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  | jq -r ".data[] | select(.[\"display-name\"] | startswith(\"$INSTANCE_CONFIG_CONTROLPLANE\")).id")

save_resource_env "INSTANCE_CONFIG_ID_CPL" "${INSTANCE_CONFIG_ID_CPL}"

#
# oci compute-management instance-pool create --generate-param-json-input load-balancers
cat <<EOF > ./instance-pool-loadbalancers-cpl.json
[
  {
    "backendSetName": "$BES_API_NAME",
    "loadBalancerId": "$NLB_ID",
    "port": 6443,
    "vnicSelection": "PrimaryVnic"
  },
  {
    "backendSetName": "$BES_MCS_NAME",
    "loadBalancerId": "$NLB_ID",
    "port": 22623,
    "vnicSelection": "PrimaryVnic"
  }
]
EOF

# oci compute-management instance-pool create --generate-param-json-input placement-configurations
cat <<EOF > ./instance-pool-placement.json
[
  {
    "availabilityDomain": "$AVAILABILITY_DOMAIN",
    "faultDomains": ["FAULT-DOMAIN-1","FAULT-DOMAIN-2","FAULT-DOMAIN-3"],
    "primarySubnetId": "$SUBNET_ID_PRIVATE",
  }
]
EOF

oci compute-management instance-pool create \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --instance-configuration-id "$INSTANCE_CONFIG_ID_CPL" \
  --size 3 \
  --display-name "$INSTANCE_POOL_CONTROLPLANE" \
  --placement-configurations "file://instance-pool-placement.json" \
  --load-balancers file://instance-pool-loadbalancers-cpl.json

INSTANCE_POOL_ID_CPL=$(oci compute-management instance-pool list \
    --compartment-id  $COMPARTMENT_ID_OPENSHIFT \
    | jq -r ".data[] | select(
        (.[\"display-name\"]==\"$INSTANCE_POOL_CONTROLPLANE\") and
        (.[\"lifecycle-state\"]==\"RUNNING\")
    ).id")

save_resource_env "INSTANCE_POOL_ID_CPL" "${INSTANCE_POOL_ID_CPL}"

# oci compute-management instance-pool update --instance-pool-id $INSTANCE_POOL_ID_CPL --size 3



echo "======================"
echo "CREATING STACK:WORKERS"
echo "======================"

INSTANCE_CONFIG_COMPUTE="${CLUSTER_NAME}-compute"

# oci compute-management instance-configuration create --generate-param-json-input instance-details
cat <<EOF > ./instance-config-details-compute.json
{
  "instanceType": "compute",
  "launchDetails": {
    "agentConfig": {"areAllPluginsDisabled": true},
    "compartmentId": "$COMPARTMENT_ID_OPENSHIFT",
    "createVnicDetails": {
      "assignPrivateDnsRecord": true,
      "assignPublicIp": false,
      "nsgIds": ["$NSG_ID_CMP"],
      "subnetId": "$SUBNET_ID_PRIVATE"
    },
    "definedTags": {
      "$CLUSTER_NAME": {
        "role": "worker"
      }
    },
    "displayName": "${CLUSTER_NAME}-worker",
    "launchMode": "PARAVIRTUALIZED",
    "metadata": {"user_data": "$(base64 -w0 < $INSTALL_DIR/worker.ign)"},
    "shape": "$INSTANCE_SHAPE",
    "shapeConfig": {"memoryInGBs":16.0,"ocpus":8.0},
    "sourceDetails": {"bootVolumeSizeInGBs":120,"bootVolumeVpusPerGB":20,"imageId":"${IMAGE_ID}","sourceType":"image"}
  }
}
EOF

oci compute-management instance-configuration create \
  --display-name "$INSTANCE_CONFIG_COMPUTE" \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --instance-details file://instance-config-details-compute.json

INSTANCE_POOL_COMPUTE="${CLUSTER_NAME}-compute"
INSTANCE_CONFIG_ID_CMP=$(oci compute-management instance-configuration list \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  | jq -r ".data[] | select(.[\"display-name\"] | startswith(\"$INSTANCE_CONFIG_COMPUTE\")).id")

save_resource_env "INSTANCE_CONFIG_ID_CMP" "${INSTANCE_CONFIG_ID_CMP}"

BES_HTTP_NAME=$(oci nlb backend-set list --network-load-balancer-id $NLB_ID \
  | jq -r '.data.items[] | select(.name | endswith("http")).name')
BES_HTTPS_NAME=$(oci nlb backend-set list --network-load-balancer-id $NLB_ID \
  | jq -r '.data.items[] | select(.name | endswith("https")).name')

#
# oci compute-management instance-pool create --generate-param-json-input load-balancers
cat <<EOF > ./instance-pool-loadbalancers-cmp.json
[
  {
    "backendSetName": "$BES_HTTP_NAME",
    "loadBalancerId": "$NLB_ID",
    "port": 80,
    "vnicSelection": "PrimaryVnic"
  },
  {
    "backendSetName": "$BES_HTTPS_NAME",
    "loadBalancerId": "$NLB_ID",
    "port": 443,
    "vnicSelection": "PrimaryVnic"
  }
]
EOF

oci compute-management instance-pool create \
  --compartment-id $COMPARTMENT_ID_OPENSHIFT \
  --instance-configuration-id "$INSTANCE_CONFIG_ID_CMP" \
  --size 3 \
  --display-name "$INSTANCE_POOL_COMPUTE" \
  --placement-configurations "[{\"availabilityDomain\":\"$AVAILABILITY_DOMAIN\",\"faultDomains\":[\"FAULT-DOMAIN-1\",\"FAULT-DOMAIN-2\",\"FAULT-DOMAIN-3\"],\"primarySubnetId\":\"$SUBNET_ID_PRIVATE\"}]" \
  --load-balancers file://instance-pool-loadbalancers-cmp.json

INSTANCE_POOL_ID_CMP=$(oci compute-management instance-pool list \
    --compartment-id  $COMPARTMENT_ID_OPENSHIFT \
    | jq -r ".data[] | select(
        (.[\"display-name\"]==\"$INSTANCE_POOL_COMPUTE\") and
        (.[\"lifecycle-state\"]==\"RUNNING\")
    ).id")

save_resource_env "INSTANCE_POOL_ID_CMP" "${INSTANCE_POOL_ID_CMP}"

# oci compute-management instance-pool update --instance-pool-id $INSTANCE_POOL_ID_CMP --size 2


