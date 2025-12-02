#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

IC_API_KEY=$(cat "${AGENT_IBMZ_CREDENTIALS}/ibmcloud-apikey")
export IC_API_KEY

# Check if the system architecture is supported to perform the e2e installation
arch=$(uname -m)
if [[ ! " x86_64 s390x arm64 amd64 " =~  $arch  ]]; then
    echo "Error: Unsupported System Architecture : $arch."
    echo "Automation runs only on s390x, x86_64, amd64, and arm64 architectures."
    exit 1
fi

# Setting OS and Arch names required to install CLI's
if [[ "$OSTYPE" == "linux"* ]]; then
    jq_os="linux"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    jq_os="macos"
else
    echo "Unsupported OS: $OSTYPE. Automation supports only on Linux and macOS."
    exit 1
fi

case "$arch" in
    x86_64 | amd64)
        jq_arch="amd64"
        ;;
    arm64)
        jq_arch="$arch"
        ;;
    *)
        jq_arch="$arch"
        ;;
esac

# Install jq 
if ! command -v jq &> /dev/null; then
    jq_latest_tag=$(curl -s https://api.github.com/repos/jqlang/jq/tags | awk -F'"' '/"name":/ {print $4; exit}')
    echo -e "\nInstalling jq having version $jq_latest_tag..."
    curl -k -L -o $HOME/.tmp/bin/jq https://github.com/jqlang/jq/releases/download/$jq_latest_tag/jq-$jq_os-$jq_arch
    chmod +x $HOME/.tmp/bin/jq
else
    echo -e "\njq is already installed with below version, Skipping installation."
fi
jq --version

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

# 1. Login to IBM Cloud
# -----------------------------
echo "Logging in to IBM Cloud..."
ibmcloud login --apikey "$IC_API_KEY" -r "$IC_REGION" -g "$RESOURCE_GROUP" || { echo "Login failed"; exit 1; }

# -------------------------
# 2. Fetch ALL reserved IPs of all VSIs
# -------------------------
mapfile -t ALL_RESERVED_IPS < <(
  ibmcloud is instances --json |
    jq -r '.[] | .primary_network_interface.primary_ip.address'
)

echo "All Reserved IPs:" "${ALL_RESERVED_IPS[@]}"

# -------------------------
# 3. Fetch only CONTROL node IPs
# -------------------------
mapfile -t CONTROL_RIP < <(
  ibmcloud is instances --json |
    jq -r '.[] | select(.name | test("control")) | .primary_network_interface.primary_ip.address'
)

echo "All Reserved IPs:" "${CONTROL_RIP[@]}"

# -------------------------
# 4. Pick one control node subnet for MetalLB
# -------------------------
BASE_IP="${CONTROL_RIP[0]}"
SUBNET_PREFIX=$(echo "$BASE_IP" | awk -F. '{print $1"."$2"."$3"."}')
BASE_LAST_OCTET=$(echo "$BASE_IP" | awk -F. '{print $4}')

echo "Using subnet: ${SUBNET_PREFIX}0/24"

# -------------------------
# 5. Function to check collision with existing VSIs
# -------------------------
function ip_in_list() {
    local ip=$1
    for eip in "${ALL_RESERVED_IPS[@]}"; do
        if [[ "$ip" == "$eip" ]]; then
            return 0    # FOUND collision
        fi
    done
    return 1            # NO collision
}

# -------------------------
# 6. Find next available 3-IP range in subnet
# -------------------------
START=$((BASE_LAST_OCTET + 1))

while true; do
    IP1="${SUBNET_PREFIX}${START}"
    IP2="${SUBNET_PREFIX}$((START + 1))"
    IP3="${SUBNET_PREFIX}$((START + 2))"

    # Check collision with any VSI Reserved IP
    if ip_in_list "$IP1" || ip_in_list "$IP2" || ip_in_list "$IP3"; then
        echo "Collision detected with existing VSI IPs: $IP1 $IP2 $IP3"
        START=$((START + 3))   # move to next block
        continue
    fi

    # SUCCESS: no collisions
    METALLB_RANGE_START="$IP1"
    METALLB_RANGE_END="$IP3"
    break
done

echo "Selected MetalLB Safe Range: ${METALLB_RANGE_START}-${METALLB_RANGE_END}"

echo "install metallb operator"
# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-system
  namespace: metallb-system
spec: {}
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: metallb-operator
  namespace: metallb-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: metallb-operator
  source: "${METALLB_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

RETRIES=30
CSV=
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    CSV=$(oc get subscription -n metallb-system metallb-operator -o jsonpath='{.status.installedCSV}')
    continue
  fi

  if [[ $(oc get csv -n metallb-system ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "metallb-operator is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: metallb-operator is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy metallb-operator"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n metallb-system -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n metallb-system
  exit 1
fi
echo "successfully installed metallb-operator"

# Install metallb operator

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
EOF

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_RANGE_START}-${METALLB_RANGE_END}
EOF

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
   - metallb
EOF
