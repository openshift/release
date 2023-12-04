#!/bin/bash

set -x

# Hosted Control Plane parameters
hcp_ns="$HC_NS-$HC_NAME"
export hcp_ns

# InfraEnv configs
ssh_key_file="${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-pub-key"
ssh_key=$(cat ${ssh_key_file})
export ssh_key

# Creating cluster imageset
cat <<EOF | oc create -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: img-${hcp_ns}-appsub
spec:
  releaseImage: ${OCP_IMAGE_MULTI}
EOF

# Creating Provisioning
if ! oc get provisioning provisioning-configuration &> /dev/null; then
  # If it doesn't exist, create it
  cat <<EOF | oc create -f -
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  provisioningNetwork: Disabled
  watchAllNamespaces: true
EOF
else
  echo "Resource provisioning-configuration already exists. Skipping creation."
fi

# Installing hypershift cli
MCE_VERSION=$(oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
HYPERSHIFT_CLI_NAME=hcp
if (( $(echo "$MCE_VERSION < 2.4" | bc -l) )); then
 echo "MCE version is less than 2.4, using the hypershift cli name."
 HYPERSHIFT_CLI_NAME=hypershift
fi

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

# Applying mirror config
echo "$(date) Applying mirror config"
cat <<EOF | oc create -f -
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
echo "$(date) Creating AgentServiceConfig"
envsubst <<"EOF" | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: AgentServiceConfig
metadata:
 name: agent
spec:
  mirrorRegistryRef:
    name: mirror-config
  databaseStorage:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 10Gi
  filesystemStorage:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 10Gi
  osImages:
    - openshiftVersion: "${OCP_VERSION}"
      version: "${OCP_RELEASE_VERSION}"
      url: "${ISO_URL}"
      rootFSUrl: "${ROOT_FS_URL}"
      cpuArchitecture: s390x
EOF

oc wait --timeout=5m --for=condition=DeploymentsHealthy agentserviceconfig agent
echo "$(date) AgentServiceConfig is ready"

set +x
# Setting up pull secret with brew token
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
brew_token_file="${AGENT_IBMZ_CREDENTIALS}/brew-token"
cat /tmp/.dockerconfigjson | jq --arg brew_token "$(cat ${brew_token_file})" '.auths += {"brew.registry.redhat.io": {"auth": $brew_token}}' > /tmp/pull-secret
PULL_SECRET_FILE=/tmp/pull-secret
set -x

# Creating agent hosted cluster manifests
echo "$(date) Creating agent hosted cluster manifests"
oc create ns ${hcp_ns}
mkdir /tmp/hc-manifests

ICSP_COMMAND=""
if [[ $ENABLE_ICSP == "true" ]]; then
  ICSP_COMMAND=$(echo "--image-content-sources ${SHARED_DIR}/mgmt_iscp.yaml")
fi

${HYPERSHIFT_CLI_NAME} create cluster agent ${ICSP_COMMAND} \
    --name=${HC_NAME} \
    --pull-secret="${PULL_SECRET_FILE}" \
    --agent-namespace=${hcp_ns} \
    --base-domain=${HYPERSHIFT_BASEDOMAIN} \
    --api-server-address=api.${HC_NAME}.${HYPERSHIFT_BASEDOMAIN} \
    --ssh-key=${ssh_key_file} \
    --control-plane-availability-policy ${HYPERSHIFT_CP_AVAILABILITY_POLICY} \
    --infra-availability-policy ${HYPERSHIFT_INFRA_AVAILABILITY_POLICY} \
    --namespace $HC_NS \
    --release-image=${OCP_IMAGE_MULTI} --render > /tmp/hc-manifests/cluster-agent.yaml

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
      type: Route
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

oc wait --timeout=15m --for=condition=Available --namespace=${HC_NS} hostedcluster/${HC_NAME}
echo "$(date) Agent cluster is available"

# Applying InfraEnv
echo "$(date) Applying InfraEnv"
envsubst <<"EOF" | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${HC_NAME}
  namespace: ${hcp_ns}
spec:
  cpuArchitecture: s390x
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${ssh_key}
EOF

# Waiting for discovery iso file to ready
oc wait --timeout=10m --for=condition=ImageCreated --namespace=${hcp_ns} infraenv/${HC_NAME}
echo "$(date) ISO Download url is ready"

# Download hosted cluster kubeconfig
echo "$(date) Create hosted cluster kubeconfig"
${HYPERSHIFT_CLI_NAME} create kubeconfig --namespace=${HC_NS} --name=${HC_NAME} >${SHARED_DIR}/nested_kubeconfig
