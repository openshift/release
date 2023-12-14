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
POWERVS_VSI_SYS_TYPE="e980"

# MCE agentserviceconfig configs
export DB_VOLUME_SIZE="10Gi"
export FS_VOLUME_SIZE="10Gi"
export ARCH="ppc64le"

# InfraEnv configs
SSH_PUB_KEY_FILE="${AGENT_POWER_CREDENTIALS}/ssh-publickey"
SSH_PUB_KEY=$(cat ${SSH_PUB_KEY_FILE})
export SSH_PUB_KEY

# Installing required tools
echo "$(date) Installing required tools"
mkdir /tmp/ibm_cloud_cli
curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.16.1/IBM_Cloud_CLI_2.16.1_amd64.tar.gz
tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
curl -L https://github.com/mikefarah/yq/releases/download/v4.31.2/yq_linux_amd64 -o /tmp/bin/yq && chmod +x /tmp/bin/yq
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
ibmcloud pi st ${POWERVS_INSTANCE_CRN}
ibmcloud cis instance-set ${CIS_INSTANCE}

# Setting IBMCLOUD_TRACE to true to enable debug logs for pi and cis operations
export IBMCLOUD_TRACE=true

# Creating VM as first operation as it would take some time to alive to retrieve the network interface details like ip and mac
echo "$(date) Creating VSI in PowerVS instance"
ibmcloud pi instance-create ${POWERVS_VSI_NAME} --image ${POWERVS_IMAGE} --network ${POWERVS_NETWORK} --memory ${POWERVS_VSI_MEMORY} --processors ${POWERVS_VSI_PROCESSORS} --processor-type ${POWERVS_VSI_PROC_TYPE} --sys-type ${POWERVS_VSI_SYS_TYPE} --replicants ${HYPERSHIFT_NODE_COUNT} --replicant-scheme suffix

# Applying mirror config
echo "$(date) Applying mirror config"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: mirror-config
  namespace: multicluster-engine
  labels:
    app: assisted-service
data:
  registries.conf: |
    unqualified-search-registries = ["registry.access.redhat.com", "docker.io"]

    [[registry]]
      location = "registry.stage.redhat.io"
      insecure = false
      blocked = false
      mirror-by-digest-only = true
      prefix = ""

      [[registry.mirror]]
        location = "brew.registry.redhat.io"
        insecure = false

    [[registry]]
      location = "registry.redhat.io"
      insecure = false
      blocked = false
      mirror-by-digest-only = true
      prefix = ""

      [[registry.mirror]]
        location = "brew.registry.redhat.io"
        insecure = false

    [[registry]]
      location = "registry.redhat.io/rhacm2"
      insecure = false
      blocked = false
      mirror-by-digest-only = true
      prefix = ""

      [[registry.mirror]]
        location = "brew.registry.redhat.io/rhacm2"
        insecure = false

    [[registry]]
      location = "registry-proxy.engineering.redhat.com"
      insecure = false
      blocked = false
      mirror-by-digest-only = true
      prefix = ""

      [[registry.mirror]]
        location = "brew.registry.redhat.io"
        insecure = false

    [[registry]]
      location = "registry.redhat.io/multicluster-engine"
      insecure = false
      blocked = false
      mirror-by-digest-only = true
      prefix = ""

      [[registry.mirror]]
        location = "brew.registry.redhat.io/multicluster-engine"
        insecure = false
EOF


 oc adm release info ${OCP_IMAGE_MULTI} --filter-by-os=linux/ppc64le -o json > ocpversion.json
 OPENSHIFT_VERSION="$(cat ocpversion.json | jq -r . | grep "BUILD_VERSION=v" |  tr -d 'v",' | awk -F '=' '{print $2}')"
 export OPENSHIFT_VERSION

 if [[ "${OPENSHIFT_VERSION}" == *"4.14."* ]]
 then
   RHCOS_VERSION="4.14-9.2"
 elif [[ "${OPENSHIFT_VERSION}" == *"4.15."* ]]
 then
   RHCOS_VERSION="4.15-9.2"
 else
   echo "unrecognized version for RHCOS"
   exit 1
 fi

 RHCOS_BUILD_VERSION=$(cat ocpversion.json | jq -r '.displayVersions."machine-os".Version')
 export RHCOS_BUILD_VERSION
 export ISO_URL="https://rhcos.mirror.openshift.com/art/storage/prod/streams/${RHCOS_VERSION}/builds/${RHCOS_BUILD_VERSION}/ppc64le/rhcos-${RHCOS_BUILD_VERSION}-live.ppc64le.iso"
 export ROOT_FS_URL="https://rhcos.mirror.openshift.com/art/storage/prod/streams/${RHCOS_VERSION}/builds/${RHCOS_BUILD_VERSION}/ppc64le/rhcos-${RHCOS_BUILD_VERSION}-live-rootfs.ppc64le.img"

# Creating AgentServiceConfig
echo "$(date) Creating AgentServiceConfig"
envsubst <<"EOF" | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: AgentServiceConfig
metadata:
  name: agent
spec:
  databaseStorage:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: ${DB_VOLUME_SIZE}
  filesystemStorage:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: ${FS_VOLUME_SIZE}
  mirrorRegistryRef:
    name: mirror-config
  osImages:
    - openshiftVersion: "${OPENSHIFT_VERSION}"
      version: "${RHCOS_BUILD_VERSION}"
      url: "${ISO_URL}"
      rootFSUrl: "${ROOT_FS_URL}"
      cpuArchitecture: "${ARCH}"
EOF

oc wait --timeout=5m --for=condition=DeploymentsHealthy agentserviceconfig agent
echo "$(date) AgentServiceConfig ready"

set +x
# Setting up pull secret with brew token
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
brewToken="${AGENT_POWER_CREDENTIALS}/brew-token"
cat /tmp/.dockerconfigjson | jq --arg brew_token "$(cat ${brewToken})" '.auths += {"brew.registry.redhat.io": {"auth": $brew_token}}' > /tmp/pull-secret
PULL_SECRET=/tmp/pull-secret
set -x

# Creating agent hosted cluster manifests
echo "$(date) Creating agent hosted cluster manifests"
oc create ns ${HOSTED_CONTROL_PLANE_NAMESPACE}
mkdir /tmp/hc-manifests

ICSP_COMMAND=""
if [[ $ENABLE_ICSP == "true" ]]; then
  ICSP_COMMAND=$(echo "--image-content-sources ${SHARED_DIR}/mgmt_iscp.yaml")
fi

${HYPERSHIFT_CLI_NAME} create cluster agent ${ICSP_COMMAND} \
    --name=${HOSTED_CLUSTER_NAME} \
    --namespace=${CLUSTERS_NAMESPACE} \
    --pull-secret=${PULL_SECRET} \
    --agent-namespace=${HOSTED_CONTROL_PLANE_NAMESPACE} \
    --base-domain=${HYPERSHIFT_BASE_DOMAIN} \
    --api-server-address=api.${HOSTED_CLUSTER_NAME}.${HYPERSHIFT_BASE_DOMAIN} \
    --ssh-key=${SSH_PUB_KEY_FILE}\
    --release-image=${OCP_IMAGE_MULTI} \
    --control-plane-availability-policy=${CP_AVAILABILITY_POLICY} \
    --infra-availability-policy ${HYPERSHIFT_INFRA_AVAILABILITY_POLICY} \
    --render > /tmp/hc-manifests/cluster-agent.yaml

# Split the manifest to replace routing strategy of various services
csplit -f /tmp/hc-manifests/manifest_ -k /tmp/hc-manifests/cluster-agent.yaml /---/ "{6}"

# Service strategy to replace
printf "  - service: APIServer
    servicePublishingStrategy:
      type: LoadBalancer
  - service: OAuthServer
    servicePublishingStrategy:
      type: Route
  - service: OIDC
    servicePublishingStrategy:
      type: None
  - service: Konnectivity
    servicePublishingStrategy:
      type: Route
  - service: Ignition
    servicePublishingStrategy:
      type: Route
  - service: OVNSbDb
    servicePublishingStrategy:
      type: Route
" > /tmp/hc-manifests/replacement.yaml

for file in /tmp/hc-manifests/manifest_*
do
    if grep -q 'kind: HostedCluster' "$file"
    then
        yq eval-all -i 'select(fileIndex==0).spec.services = select(fileIndex==1) | select(fileIndex==0)' "$file" "/tmp/hc-manifests/replacement.yaml"
    fi
done

# Applying agent cluster manifests
echo "$(date) Applying agent cluster manifests"
ls /tmp/hc-manifests/manifest_* | awk ' { print " -f " $1 } ' | xargs oc apply

oc wait --timeout=15m --for=condition=Available --namespace=${CLUSTERS_NAMESPACE} hostedcluster/${HOSTED_CLUSTER_NAME}
echo "$(date) Agent cluster is available"

# Applying InfraEnv
echo "$(date) Applying InfraEnv"
envsubst <<"EOF" | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${HOSTED_CLUSTER_NAME}
  namespace: ${HOSTED_CONTROL_PLANE_NAMESPACE}
spec:
  cpuArchitecture: $ARCH
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
    instance_id=$(ibmcloud pi instances --json | jq -r --arg serverName $instance '.pvmInstances[] | select (.serverName == $serverName ) | .pvmInstanceID')
    if [ -z "$instance_id" ]; then
        continue
    fi
    INSTANCE_ID+=("$instance_id")
done
MAC_ADDRESSES=()
IP_ADDRESSES=()
for instance in "${INSTANCE_ID[@]}"; do
    for ((i=1; i<=20; i++)); do
        instance_info=$(ibmcloud pi instance $instance --json)
        mac_address=$(echo "$instance_info" | jq -r '.networks[].macAddress')
        ip_address=$(echo "$instance_info" | jq -r '.networks[].ipAddress')

        if [ -z "$mac_address" ] || [ -z "$ip_address" ]; then
            echo "$(date) Waiting for mac and ip to be populated in $instance"
            sleep 60
            continue
        fi

        MAC_ADDRESSES+=("$mac_address")
        IP_ADDRESSES+=("$ip_address")
        break
    done
done

if [ ${#MAC_ADDRESSES[@]} -ne ${HYPERSHIFT_NODE_COUNT} ] || [ ${#IP_ADDRESSES[@]} -ne ${HYPERSHIFT_NODE_COUNT} ]; then
  echo "Required VM's addresses not collected, exiting test"
  echo "Collected MAC Address: ${MAC_ADDRESSES[]}, IP Address: ${IP_ADDRESSES[]}}"
  exit 1
fi

# Creating dns record for ingress
# Assigning first node's ip to ingress dns record
echo "$(date) Creating dns record for ingress"
ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type A --name "*.apps.${HOSTED_CLUSTER_NAME}" --content "${IP_ADDRESSES[0]}"

# Waiting for discovery iso file to ready
oc wait --timeout=10m --for=condition=ImageCreated --namespace=${HOSTED_CONTROL_PLANE_NAMESPACE} infraenv/${HOSTED_CLUSTER_NAME}
echo "$(date) ISO Download url ready"

# Extracting iso download url
DISCOVERY_ISO_URL=$(oc get infraenv/${HOSTED_CLUSTER_NAME} -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.isoDownloadURL')
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

# Rebooting vm to boot from the network
for instance in "${INSTANCE_ID[@]}"; do
    sleep 120
    ibmcloud pi instance-soft-reboot $instance
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
            oc -n ${CLUSTERS_NAMESPACE} scale nodepool ${HOSTED_CLUSTER_NAME} --replicas ${agentsApproved}
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
oc wait --all=true agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster --timeout=45m

# Download guest cluster kubeconfig
echo "$(date) Setup nested_kubeconfig"
${HYPERSHIFT_CLI_NAME} create kubeconfig --namespace=${CLUSTERS_NAMESPACE} --name=${HOSTED_CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig

# Setting nodeSelector on ingresscontroller  to first agent to make sure router pod spawns on first agent,
# since *.apps DNS record is pointing to first agent's IP.
oc patch ingresscontroller default -n openshift-ingress-operator -p '{"spec": {"nodePlacement": {"nodeSelector": { "matchLabels": { "kubernetes.io/hostname": "'"${INSTANCE_NAMES[0]}"'"}}, "tolerations": [{ "effect": "NoSchedule", "key": "kubernetes.io/hostname", "operator": "Exists"}]}}}' --type=merge --kubeconfig=${SHARED_DIR}/nested_kubeconfig

cat <<EOF> "${SHARED_DIR}/proxy-conf.sh"
export HTTP_PROXY=http://${BASTION}:2005/
export HTTPS_PROXY=http://${BASTION}:2005/
export NO_PROXY="static.redhat.com,redhat.io,amazonaws.com,quay.io,openshift.org,openshift.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"

export http_proxy=http://${BASTION}:2005/
export https_proxy=http://${BASTION}:2005/
export no_proxy="static.redhat.com,redhat.io,amazonaws.com,quay.io,openshift.org,openshift.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"
EOF
