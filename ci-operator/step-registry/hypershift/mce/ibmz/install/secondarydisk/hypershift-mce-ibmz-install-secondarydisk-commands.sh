#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

IC_API_KEY=$(cat "${AGENT_IBMZ_CREDENTIALS}/ibmcloud-apikey")
export IC_API_KEY

# Check if the system architecture is supported to perform the e2e installation
arch=$(uname -m)
if [[ ! " x86_64 s390x arm64 amd64 " =~ " $arch " ]]; then
    echo "Error: Unsupported System Architecture : $arch."
    echo "Automation runs only on s390x, x86_64, amd64, and arm64 architectures."
    exit 1
fi

# Setting OS and Arch names required to install CLI's
if [[ "$OSTYPE" == "linux"* ]]; then
    linux_type=$(grep '^ID=' /etc/os-release | cut -d '=' -f 2)
    oc_os="linux"
    jq_os="linux"
    ic_os="linux"
    nmstate_os="linux"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    oc_os="mac"
    jq_os="macos"
    ic_os="osx"
    nmstate_os="macos"
else
    echo "Unsupported OS: $OSTYPE. Automation supports only on Linux and macOS."
    exit 1
fi

case "$arch" in
    x86_64 | amd64)
        nmstate_arch="x64"
        jq_arch="amd64"
        ;;
    arm64)
        nmstate_arch="aarch64"
        jq_arch="$arch"
        ;;
    *)
        nmstate_arch="$arch"
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

job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export job_id
export CLUSTER_NAME="hcp-s390x-mgmt-ci-$job_id"

# Login to IBM Cloud
# -----------------------------
echo "Logging in to IBM Cloud..."
ibmcloud login --apikey "$IC_API_KEY" -r "$REGION" -g "$RESOURCE_GROUP" || { echo "Login failed"; exit 1; }

# Fetching the VSI list with the Zone field
# ------------------------------
echo "Fetching the VSIs with zone names"
nodes=$(ibmcloud is instances --json | \
  jq -r --arg CN "$CLUSTER_NAME" \
    '.[]
     | select(.name | test($CN + ".*(control|compute)"))
     | "\(.name) \(.id) \(.zone.name)"')

echo "$nodes"

# Count nodes
node_count=$(echo "$nodes" | wc -l | tr -d ' ')
compute_count=$(echo "$nodes" | grep -c "compute" || true)

echo "Node count: $node_count"
echo "Compute nodes: $compute_count"

# -----------------------------
# Determine Cluster Type
# -----------------------------
if [[ "$node_count" -eq 3 && "$compute_count" -eq 0 ]]; then
    echo "Cluster Type: COMPACT"
    cluster_type="compact"
elif [[ "$node_count" -ge 3 && "$compute_count" -gt 0 ]]; then
    echo "Cluster Type: HA"
    cluster_type="ha"
else
    echo "ERROR: Unknown cluster type or unexpected node layout"
    exit 1
fi

echo
echo "Processing nodes for cluster type: $cluster_type"
echo

# -----------------------------
# Process Nodes
# -----------------------------
while read -r VSI_NAME VSI_ID VSI_ZONE; do
  [[ -z "$VSI_NAME" ]] && continue

  # Skip control nodes for HA clusters (attach volumes only to compute)
  if [[ "$cluster_type" == "ha" && "$VSI_NAME" != *compute* ]]; then
      continue
  fi

  echo "--------------------------------------------"
  echo "Node: $VSI_NAME"
  echo "ID:   $VSI_ID"
  echo "Zone: $VSI_ZONE"
  echo "--------------------------------------------"

  # Generate volume name
  VOL_NAME="bsv-${VSI_NAME}"

  echo "Creating Volume: $VOL_NAME in zone: $VSI_ZONE"
  VOL_JSON=$(ibmcloud is volume-create "$VOL_NAME" sdp "$VSI_ZONE" \
                --capacity 100 \
                --bandwidth 2000 \
                --json)

  VOLUME_ID=$(echo "$VOL_JSON" | jq -r '.id')
  echo "Volume created: $VOLUME_ID"

  echo "Attaching volume to VSI..."
  ATTACH_JSON=$(ibmcloud is instance-volume-attachment-add "$VSI_NAME" "$VSI_ID" \
                  --volume "$VOLUME_ID" \
                  --json)

  ATTACH_ID=$(echo "$ATTACH_JSON" | jq -r '.id')
  echo "Attachment ID: $ATTACH_ID"

  echo "Validating attachment..."
  ibmcloud is instance-volume-attachments "$VSI_ID"
  echo

done <<< "$nodes"

echo
echo "===================================================="
echo "Volumes created and attached successfully."
echo "Cluster type: $cluster_type"
echo "===================================================="




