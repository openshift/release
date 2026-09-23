#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1091
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# logger function prints standard logs
logger() {
    local level="$1"
    local message="$2"
    local timestamp

    # Generate a timestamp for the log entry
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Print the log message with the level and timestamp
    echo "[$timestamp] [$level] $message"
}

function exec_command() {
    local cmd="$1"
    logger "INFO" "Execute Command: ${cmd}"
    eval "${cmd}"
}

WIN_NODES_NAMES=$(oc get no -l beta.kubernetes.io/os=windows -o jsonpath='{.items[*].metadata.name}')
# Check if WIN_NODES_NAMES is empty
if [ -n "$WIN_NODES_NAMES" ]; then
    logger "INFO" "Found Windows nodes: $WIN_NODES_NAMES"
    # Use IFS to split the string by spaces and store it in an array
    IFS=' ' read -r -a win_nodes_array <<< "$WIN_NODES_NAMES" 
else
    logger "ERROR" "No Windows nodes found." && exit 1
fi

WIN_NODE_NAME=${win_nodes_array[0]}
WIN_NODE_ID=$(oc get nodes "${WIN_NODE_NAME}" -o jsonpath='{.spec.providerID}'|awk -F '/' '{print $NF}')
if [ -n "$WIN_NODE_ID" ]; then
    logger "INFO" "${WIN_NODE_NAME} nodeID is ${WIN_NODE_ID}"
else
    logger "ERROR" "Could not nodeID for node ${WIN_NODE_NAME}"
    exit 1
fi

WIN_NODE_IP=$(oc get nodes "${WIN_NODE_NAME}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
logger "INFO" "${WIN_NODE_NAME} internal ip is ${WIN_NODE_IP}"
if [ -n "$WIN_NODE_IP" ]; then
    export WIN_NODE_IP
else
    logger "ERROR" "Could not retrieve IP for node ${WIN_NODE_NAME}"
    exit 1
fi

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        logger "ERROR" "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

logger "INFO" "New-SmbShare TestShare on the windows node"
ssh_key_file_name="ssh-privatekey"
ssh_key=${CLUSTER_PROFILE_DIR}/${ssh_key_file_name}
bastion_dns=$(oc get service --all-namespaces -l run=ssh-bastion -o go-template="{{ with (index (index .items 0).status.loadBalancer.ingress 0) }}{{ or .hostname .ip }}{{end}}")
ssh_proxy_cmd_template="ssh -i ${ssh_key} -o StrictHostKeyChecking=no -o ProxyCommand=\"ssh -i ${ssh_key} -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -W %h:%p core@${bastion_dns}\" Administrator@NODE_IP \"powershell.exe -NonInteractive -ExecutionPolicy Bypass -Command \\\"Get-WmiObject -Class Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber; New-NetFirewallRule -DisplayName 'SMB' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -EdgeTraversalPolicy Allow; mkdir C:\\smbshare; New-LocalUser -Name sambauser -Password (ConvertTo-SecureString -Force -AsPlainText 'OpenshiftWin2022samba'); New-SmbShare -Name TestShare -Path C:\\smbshare -FullAccess sambauser\\\"\""
smb_config_cmds="${ssh_proxy_cmd_template//NODE_IP/${WIN_NODE_IP}}"

exec_command "${smb_config_cmds}" 

logger "INFO" "Adding SMB allow rule to the windows node Security Group"
REGION=${REGION:-$LEASED_RESOURCE}
# Special setting for C2S/SC2S
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  source_region=$(jq -r ".\"${REGION}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  REGION=$source_region
fi

# Get security groups attached to instances with the specified instance id
SECURITY_GROUP_IDS=$(aws ec2 describe-instances \
    --region "${REGION}" \
    --instance-ids "${WIN_NODE_ID}"\
    --query "Reservations[*].Instances[*].SecurityGroups[*].GroupId" \
    --output text)

# Loop through each security group and add the SMB rule
for SG_ID in $SECURITY_GROUP_IDS; do
    logger "INFO" "Adding SMB allow rule to Security Group: $SG_ID"
    aws ec2 authorize-security-group-ingress \
        --region "${REGION}" \
        --group-id "${SG_ID}" \
        --protocol tcp \
        --port 445 \
        --cidr 0.0.0.0/0
done

logger "INFO" "Create the samba storageclass"
envsubst <<"EOF" | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: smbcreds
  namespace: default
stringData:
  username: sambauser
  password: OpenshiftWin2022samba
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: samba
provisioner: smb.csi.k8s.io
parameters:
  source: //$WIN_NODE_IP/TestShare
  csi.storage.k8s.io/provisioner-secret-name: smbcreds
  csi.storage.k8s.io/provisioner-secret-namespace: default
  csi.storage.k8s.io/node-stage-secret-name: smbcreds
  csi.storage.k8s.io/node-stage-secret-namespace: default
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - dir_mode=0777
  - file_mode=0777
  - noperm
  - mfsymlinks
  - cache=strict
  - noserverino
EOF
