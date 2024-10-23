#!/bin/bash

set -x

# Agent hosted cluster configs
CLUSTERS_NAMESPACE="local-cluster"
HOSTED_CLUSTER_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HOSTED_CLUSTER_NAME
export HOSTED_CONTROL_PLANE_NAMESPACE="${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"

# PowerVS VSI(Virtual Server Instance) configs
POWERVS_VSI_NAME="${HOSTED_CLUSTER_NAME}-worker"
POWERVS_VSI_MEMORY=16
POWERVS_VSI_PROCESSORS=0.5
POWERVS_VSI_PROC_TYPE="shared"
POWERVS_VSI_SYS_TYPE="s922"

# InfraEnv configs
SSH_PUB_KEY_FILE="${AGENT_POWER_CREDENTIALS}/ssh-publickey"
SSH_PUB_KEY=$(cat ${SSH_PUB_KEY_FILE})
export SSH_PUB_KEY
export INFRAENV_NAME=${HOSTED_CLUSTER_NAME}-ppc64le

# Installing required tools
echo "$(date) Installing required tools"
mkdir /tmp/ibm_cloud_cli
curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.16.1/IBM_Cloud_CLI_2.16.1_amd64.tar.gz
tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
export PATH=$PATH:/tmp/bin

MCE_VERSION=$(oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
HYPERSHIFT_CLI_NAME=hcp
if (( $(echo "$MCE_VERSION < 2.4" | bc -l) )); then
 echo "MCE version is less than 2.4, use hypershift command"
 HYPERSHIFT_CLI_NAME=hypershift
fi

# Installing hypershift cli
echo "$(date) Installing hypershift cli"
mkdir /tmp/${HYPERSHIFT_CLI_NAME}_cli
downURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_CLI_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
curl -k --output /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz ${downURL}
tar -xvf /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz -C /tmp/${HYPERSHIFT_CLI_NAME}_cli
chmod +x /tmp/${HYPERSHIFT_CLI_NAME}_cli/${HYPERSHIFT_CLI_NAME}
export PATH=$PATH:/tmp/${HYPERSHIFT_CLI_NAME}_cli

# IBM cloud login
echo | ibmcloud login --apikey @"${AGENT_POWER_CREDENTIALS}/ibmcloud-apikey"

# Installing required ibmcloud plugins
echo "$(date) Installing required ibmcloud plugins"
ibmcloud plugin install power-iaas
ibmcloud plugin install cis

# Set target powervs and cis service instance
ibmcloud pi ws tg ${POWERVS_INSTANCE_CRN}
ibmcloud cis instance-set ${CIS_INSTANCE}

# Setting IBMCLOUD_TRACE to true to enable debug logs for pi and cis operations
export IBMCLOUD_TRACE=true

# Creating VM as first operation as it would take some time to alive to retrieve the network interface details like ip and mac
echo "$(date) Creating VSI in PowerVS instance"
ibmcloud pi ins create ${POWERVS_VSI_NAME} --image ${POWERVS_IMAGE} --subnets ${POWERVS_NETWORK} --memory ${POWERVS_VSI_MEMORY} --processors ${POWERVS_VSI_PROCESSORS} --processor-type ${POWERVS_VSI_PROC_TYPE} --sys-type ${POWERVS_VSI_SYS_TYPE} --replicants ${HYPERSHIFT_NODE_COUNT} --replicant-scheme suffix --replicant-affinity-policy affinity

MCE_VERSION=$(oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
ARCH="ppc64le"
if (( $(echo "$MCE_VERSION < 2.6" | bc -l) )); then
 # Support for using ppc64le arch added after MCE 2.6
 ARCH="amd64"
fi

echo "$(date) Creating Nodepool"
cat <<EOF | oc create -f -
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: ${HOSTED_CLUSTER_NAME}-ppc64le
  namespace: ${CLUSTERS_NAMESPACE}
spec:
  arch: ${ARCH}
  clusterName: ${HOSTED_CLUSTER_NAME}
  management:
    autoRepair: false
    upgradeType: InPlace
  nodeDrainTimeout: 0s
  platform:
    agent:
      agentLabelSelector:
        matchLabels:
          inventory.agent-install.openshift.io/cpu-architecture: ppc64le
    type: Agent
  release:
    image: ${OCP_IMAGE_MULTI}
  replicas: 0
EOF

# Applying InfraEnv
echo "$(date) Applying InfraEnv"
envsubst <<"EOF" | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${INFRAENV_NAME}
  namespace: ${HOSTED_CONTROL_PLANE_NAMESPACE}
spec:
  cpuArchitecture: ppc64le
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${SSH_PUB_KEY}
EOF

HOSTED_CLUSTER_API_SERVER=$(oc get service kube-apiserver -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.loadBalancer.ingress[].hostname')

# Creating dns records in ibmcloud cis service for agents to reach hosted cluster
ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type CNAME --name "api.${HOSTED_CLUSTER_NAME}" --content "${HOSTED_CLUSTER_API_SERVER}"
ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type CNAME --name "api-int.${HOSTED_CLUSTER_NAME}" --content "${HOSTED_CLUSTER_API_SERVER}"

# Retrieving ip and mac from workers created in ibmcloud powervs
echo "$(date) Retrieving ip and mac from workers created in ibmcloud powervs"
INSTANCE_NAMES=()
if [ ${HYPERSHIFT_NODE_COUNT} -eq 1 ]; then
  INSTANCE_NAMES+=("${POWERVS_VSI_NAME}")
else
  for (( i = 1; i <= ${HYPERSHIFT_NODE_COUNT}; i++ )); do
    INSTANCE_NAMES+=("${POWERVS_VSI_NAME}-${i}")
  done
fi
INSTANCE_ID=()
for instance in "${INSTANCE_NAMES[@]}"; do
    for ((i=1; i<=20; i++)); do
        instance_id=$(ibmcloud pi ins ls --json | jq -r --arg serverName $instance '.pvmInstances[] | select (.name == $serverName ) | .id')
        if [ -z "$instance_id" ]; then
            echo "$(date) Waiting for id to be populated for $instance"
            sleep 60
            continue
        fi
        INSTANCE_ID+=("$instance_id")
        break
    done
done

MAC_ADDRESSES=()
IP_ADDRESSES=()
origins=""
for instance in "${INSTANCE_ID[@]}"; do
    for ((i=1; i<=20; i++)); do
        instance_info=$(ibmcloud pi ins get $instance --json)
        mac_address=$(echo "$instance_info" | jq -r '.networks[].macAddress')
        ip_address=$(echo "$instance_info" | jq -r '.networks[].ipAddress')
        instance_name=$(echo "$instance_info" | jq -r '.serverName')

        if [ -z "$mac_address" ] || [ -z "$ip_address" ]; then
            echo "$(date) Waiting for mac and ip to be populated for $instance"
            sleep 60
            continue
        fi

        MAC_ADDRESSES+=("$mac_address")
        IP_ADDRESSES+=("$ip_address")
        origins+="{\"name\": \"${instance_name}\", \"address\": \"${ip_address}\", \"enabled\": true},"
        break
    done
done

if [ ${#MAC_ADDRESSES[@]} -ne ${HYPERSHIFT_NODE_COUNT} ] || [ ${#IP_ADDRESSES[@]} -ne ${HYPERSHIFT_NODE_COUNT} ]; then
  echo "Required VM's addresses not collected, exiting test"
  echo "Collected MAC Address: ${MAC_ADDRESSES[]}, IP Address: ${IP_ADDRESSES[]}}"
  exit 1
fi

if [ ${USE_GLB} == "yes" ]; then
  origins="${origins%,}"
  origin_pools_json="{\"name\": \"${HOSTED_CLUSTER_NAME}\", \"origins\": [${origins}]}"

  pool_id=$(ibmcloud cis glb-pool-create -i ${CIS_INSTANCE} --json "${origin_pools_json}" --output json | jq -r '.id')

  lb_name="${HOSTED_CLUSTER_NAME}.${HYPERSHIFT_BASE_DOMAIN}"
  lb_payload="{\"name\": \"${lb_name}\",\"fallback_pool\": \"${pool_id}\",\"default_pools\": [\"${pool_id}\"]}"

  ibmcloud cis glb-create ${CIS_DOMAIN_ID} -i ${CIS_INSTANCE} --json "${lb_payload}"

  # Creating dns record for ingress
  echo "$(date) Creating dns record for ingress"
  ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type CNAME --name "*.apps.${HOSTED_CLUSTER_NAME}" --content "${lb_name}"
fi

# Waiting for discovery iso file to ready
oc wait --timeout=10m --for=condition=ImageCreated --namespace=${HOSTED_CONTROL_PLANE_NAMESPACE} infraenv/${INFRAENV_NAME}
echo "$(date) ISO Download url ready"

# Extracting iso download url
DISCOVERY_ISO_URL=$(oc get infraenv/${INFRAENV_NAME} -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.isoDownloadURL')
DISCOVERY_ISO_DOWNLOAD_LINK_FILE="/tmp/${HOSTED_CLUSTER_NAME}-iso-download-link"
echo ${DISCOVERY_ISO_URL} > ${DISCOVERY_ISO_DOWNLOAD_LINK_FILE}

# Create private key with 0600 permission for ssh purpose
SSH_PRIVATE="/tmp/ssh-privatekey"
cp "${AGENT_POWER_CREDENTIALS}/ssh-privatekey" ${SSH_PRIVATE}
chmod 0600 ${SSH_PRIVATE}

SSH_OPTIONS=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -i "${SSH_PRIVATE}")

# Scp download link file
echo "$(date) Scp iso download link"
scp "${SSH_OPTIONS[@]}" ${DISCOVERY_ISO_DOWNLOAD_LINK_FILE} root@${BASTION}:${DISCOVERY_ISO_DOWNLOAD_LINK_FILE}

serverArgs=""
for (( i = 0; i < ${HYPERSHIFT_NODE_COUNT}; i++ )); do
    serverArgs+="${INSTANCE_NAMES[i]},${MAC_ADDRESSES[i]},${IP_ADDRESSES[i]} "
    echo $serverArgs
done

# Setup pxe boot on bastion for agents to boot
echo "$(date) Setup pxe boot in bastion"
ssh "${SSH_OPTIONS[@]}" root@${BASTION} "cd ${BASTION_CI_SCRIPTS_DIR} && ./setup-pxe-boot.sh ${HOSTED_CLUSTER_NAME} ${HYPERSHIFT_NODE_COUNT} ${serverArgs}"

sleep 240

# Rebooting vm to boot from the network
for instance in "${INSTANCE_ID[@]}"; do
    ibmcloud pi ins act $instance -o soft-reboot
done

# Wait and approve the agents as they appear
echo "$(date) Approve the agents as they appear"
instanceNameIndex=0
agentsApproved=0
for ((i=1; i<=20; i++)); do
    agents=$(oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json)

    while IFS= read -r agent; do
        is_approved=$(echo "$agent" | jq -r '.spec.approved')
        if [ "${is_approved}" = "false" ]; then
            agent_name=$(echo "$agent" | jq -r '.metadata.name')

            oc -n ${HOSTED_CONTROL_PLANE_NAMESPACE} patch agent ${agent_name} -p '{"spec":{"approved":true, "hostname": "'"${INSTANCE_NAMES[instanceNameIndex]}"'"}}' --type merge
            echo "Approving agent ${agent_name}"

            instanceNameIndex=$(($instanceNameIndex+1))
            agentsApproved=$(($agentsApproved+1))

            # Once agent approved, scale the nodepool
            oc -n ${CLUSTERS_NAMESPACE} scale nodepool ${HOSTED_CLUSTER_NAME}-ppc64le --replicas ${agentsApproved}
        fi
    done< <(echo "$agents" | jq -c '.items[]')

    if [ $agentsApproved -eq ${HYPERSHIFT_NODE_COUNT} ]  ; then
        break
    fi
    echo "Waiting to approve all the agents, currently approved: ${agentsApproved}"
    sleep 60
done

if [ $agentsApproved != ${HYPERSHIFT_NODE_COUNT} ]; then
  echo "Approved agents does not match the num of workers count, agents approved: ${agentsApproved}, num of workers: ${HYPERSHIFT_NODE_COUNT}"
  echo "exiting ..."
  exit 1
fi

# Wait for agent installation to get completed
echo "$(date) Approved the agents, waiting for the installation to get completed on them"
until \
  oc wait --all=true agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster > /dev/null; do
  oc get agents -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o wide 2> /dev/null || true
  sleep 5
done

# Download guest cluster kubeconfig
echo "$(date) Setup nested_kubeconfig"
${HYPERSHIFT_CLI_NAME} create kubeconfig --namespace=${CLUSTERS_NAMESPACE} --name=${HOSTED_CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig

cat <<EOF> "${SHARED_DIR}/proxy-conf.sh"
export HTTP_PROXY=http://${BASTION}:2005/
export HTTPS_PROXY=http://${BASTION}:2005/
export NO_PROXY="static.redhat.com,redhat.io,amazonaws.com,r2.cloudflarestorage.com,quay.io,openshift.org,openshift.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"

export http_proxy=http://${BASTION}:2005/
export https_proxy=http://${BASTION}:2005/
export no_proxy="static.redhat.com,redhat.io,amazonaws.com,r2.cloudflarestorage.com,quay.io,openshift.org,openshift.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"
EOF
