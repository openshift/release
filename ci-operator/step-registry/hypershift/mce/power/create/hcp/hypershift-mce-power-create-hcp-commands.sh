#!/bin/bash

set -x

# Agent hosted cluster configs
CLUSTERS_NAMESPACE="local-cluster"
HOSTED_CLUSTER_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HOSTED_CLUSTER_NAME
export HOSTED_CONTROL_PLANE_NAMESPACE="${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"

# MCE agentserviceconfig configs
DB_VOLUME_SIZE="10Gi"
FS_VOLUME_SIZE="10Gi"

# Installing required tools
echo "$(date) Installing required tools"
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
      location = "registry.redhat.io/multicluster-engine"
      insecure = false
      blocked = false
      mirror-by-digest-only = true
      prefix = ""

      [[registry.mirror]]
        location = "brew.registry.redhat.io/multicluster-engine"
        insecure = false
EOF


# Creating AgentServiceConfig
CLUSTER_VERSION=$(oc get clusterversion -o jsonpath={..desired.version} | cut -d '.' -f 1,2)
OS_IMAGES=$(jq --arg CLUSTER_VERSION "${CLUSTER_VERSION}" '[.[] | select(.openshift_version == $CLUSTER_VERSION)]' "${SHARED_DIR}/default_os_images.json")
echo "$(date) Creating AgentServiceConfig"
cat <<EOF | oc create -f -
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
    - openshiftVersion: "${CLUSTER_VERSION}"
      version: $(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "ppc64le").version')
      url: $(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "ppc64le").url')
      cpuArchitecture: ppc64le
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
  ICSP_COMMAND=$(echo "--image-content-sources ${SHARED_DIR}/mgmt_icsp.yaml")
fi

SSH_PUB_KEY_FILE="${AGENT_POWER_CREDENTIALS}/ssh-publickey"

# Set RENDER_COMMAND based on MCE_VERSION
# >2.6: "--render-sensitive --render", else: "--render"
RENDER_COMMAND=$( (( $(awk 'BEGIN {print ("'"$MCE_VERSION"'" > 2.6)}') )) && echo "--render-sensitive --render" || echo "--render" )

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
    --node-pool-replicas -1 \
    ${RENDER_COMMAND} > /tmp/hc-manifests/cluster-agent.yaml

# Split the manifest to replace routing strategy of various services
csplit -f /tmp/hc-manifests/manifest_ -k /tmp/hc-manifests/cluster-agent.yaml /---/ "{5}"

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