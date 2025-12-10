#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

IC_API_KEY=$(cat "${AGENT_IBMZ_CREDENTIALS}/ibmcloud-apikey")
export IC_API_KEY

# Check if the system architecture is supported to perform the e2e installation
arch=$(uname -m)
if [[ ! " x86_64 s390x arm64 amd64 " =~ $arch ]]; then
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

job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export job_id
export CLUSTER_NAME="hcp-s390x-mgmt-ci-$job_id"

# Login to IBM Cloud
# -----------------------------
echo "Logging in to IBM Cloud..."
ibmcloud login --apikey "$IC_API_KEY" -r "$IC_REGION" -g "$RESOURCE_GROUP" || { echo "Login failed"; exit 1; }