#!/bin/bash

set -x
# Agent Service Config parameters
export DB_VOLUME_SIZE="10Gi"
export FS_VOLUME_SIZE="10Gi"
export ARCH="s390x"
export OCP_RELEASE_VERSION=$(curl -s "$OCP_RELEASE_FILE_URL" | awk '/machine-os / { print $2 }')

# Hosted Control Plane parameters
CLUSTERS_NAMESPACE="clusters"
HOSTED_CLUSTER_NAME="agent-ibmz"
export HOSTED_CLUSTER_NAME
export HOSTED_CONTROL_PLANE_NAMESPACE="${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"
export MACHINE_CIDR=192.168.122.0/24

# InfraEnv configs
SSH_PUB_KEY_FILE="${AGENT_IBMZ_CREDENTIALS}/ssh-publickey"
SSH_PUB_KEY=$(cat ${SSH_PUB_KEY_FILE})
export SSH_PUB_KEY

# Creating cluster imageset
cat <<EOF | oc create -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: img-OCP-RELEASE-MULTI-appsub
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
echo "$(date) Installing hypershift cli"
mkdir /tmp/hypershift_cli
downURL=$(oc get ConsoleCLIDownload hypershift-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
curl -k --output /tmp/hypershift.tar.gz ${downURL}
tar -xvf /tmp/hypershift.tar.gz -C /tmp/hypershift_cli
chmod +x /tmp/hypershift_cli/hypershift
export PATH=$PATH:/tmp/hypershift_cli

# Installing required tools
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
curl -L https://github.com/mikefarah/yq/releases/download/v4.31.2/yq_linux_amd64 -o /tmp/bin/yq && chmod +x /tmp/bin/yq
export PATH=$PATH:/tmp/bin

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
        storage: ${DB_VOLUME_SIZE}
  filesystemStorage:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: ${FS_VOLUME_SIZE}
  osImages:
    - openshiftVersion: "${OCP_VERSION}"
      version: "${OCP_RELEASE_VERSION}"
      url: "${ISO_URL}"
      rootFSUrl: "${ROOT_FS_URL}"
      cpuArchitecture: "${ARCH}"
EOF

oc wait --timeout=5m --for=condition=DeploymentsHealthy agentserviceconfig agent
echo "$(date) AgentServiceConfig ready"

set +x
# Setting up pull secret with brew token
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
brewToken="${AGENT_IBMZ_CREDENTIALS}/brew-token"
cat /tmp/.dockerconfigjson | jq --arg brew_token "$(cat ${brewToken})" '.auths += {"brew.registry.redhat.io": {"auth": $brew_token}}' > /tmp/pull-secret
PULL_SECRET_FILE=/tmp/pull-secret
set -x

# Creating agent hosted cluster manifests
echo "$(date) Creating agent hosted cluster manifests"
oc create ns ${HOSTED_CONTROL_PLANE_NAMESPACE}
mkdir /tmp/hc-manifests

hypershift create cluster agent \
    --name=${HOSTED_CLUSTER_NAME} \
    --pull-secret="${PULL_SECRET_FILE}" \
    --agent-namespace=${HOSTED_CONTROL_PLANE_NAMESPACE} \
    --base-domain=${HYPERSHIFT_BASEDOMAIN} \
    --api-server-address=api.${HOSTED_CLUSTER_NAME}.${HYPERSHIFT_BASEDOMAIN} \
    --ssh-key ${HOME}/.ssh/id_rsa.pub \
    --namespace ${CLUSTERS_NAMESPACE} \
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
  cpuArchitecture: ${ARCH}
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${SSH_PUB_KEY}
EOF

# Waiting for discovery iso file to ready
oc wait --timeout=10m --for=condition=ImageCreated --namespace=${HOSTED_CONTROL_PLANE_NAMESPACE} infraenv/${HOSTED_CLUSTER_NAME}
echo "$(date) ISO Download url ready"

# Downloading required images

INITRD_URL=$(oc get infraenv/${HOSTED_CLUSTER_NAME} -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.bootArtifacts.initrd') 
KERNEL_URL=$(oc get infraenv/${HOSTED_CLUSTER_NAME} -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.bootArtifacts.kernel')
ROOTFS_URL=$(oc get infraenv/${HOSTED_CLUSTER_NAME} -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.bootArtifacts.rootfs')

# TO DO : virsh-vol upload these 3 images to LPAR 

# Create qemu 
# TO DO : include -c URI for connecting to LPAR
for ((i = 0; i < $HYPERSHIFT_NODE_COUNT ; i++)); do
qemu-img create -f qcow2 /var/lib/libvirt/openshift-images/agent$i.qcow2 100G
done

# Boot agents
# TO DO : include -c URI for connecting to LPAR, hardcode macaddress
mac_addresses=()
for ((i = 0; i < $HYPERSHIFT_NODE_COUNT ; i++)); do
  virt-install   --name "agent-$i"   --autostart   --ram=16384   --cpu host   --vcpus=4   --location "/var/lib/libvirt/images/pxeboot/,kernel=kernel.img,initrd=initrd.img"   --disk /var/lib/libvirt/openshift-images/agent$i.qcow2   --network network=default,mac=${mac_addresses[i]}   --graphics none   --noautoconsole   --wait=-1   --extra-args "rd.neednet=1 nameserver=172.23.0.1   coreos.live.rootfs_url=http://172.23.232.140:8080/rootfs.img random.trust_cpu=on rd.luks.options=discard ignition.firstboot ignition.platform.id=metal console=tty1 console=ttyS1,115200n8 coreos.inst.persistent-kargs=console=tty1 console=ttyS1,115200n8"
done

# Wait for agents to join (max: 20 min)
for ((i=50; i>=1; i--)); do
  agents_count=$(oc get agents -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --no-headers | wc -l)
  if [ "$agents_count" -eq ${HYPERSHIFT_NODE_COUNT} ]; then
    echo "Agents attached"
    break
  else
    echo "Waiting for agents to join the cluster..., $i retries left"
  fi
  sleep 25
done

# Approve agents 
agents=$(oc get agents -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --no-headers | awk '{print $1}')
agents=$(echo "$agents" | tr '\n' ' ')
IFS=' ' read -ra agents_list <<< "$agents"
for ((i=0; i<$HYPERSHIFT_NODE_COUNT; i++)); do
     oc -n ${HOSTED_CONTROL_PLANE_NAMESPACE} patch agent ${agents_list[i]} -p "{\"spec\":{\"installation_disk_id\":\"/dev/vda\",\"approved\":true,\"hostname\":\"compute-${i}.${HYPERSHIFT_BASEDOMAIN}\"}}" --type merge
done

# scale nodepool
oc -n ${CLUSTERS_NAMESPACE} scale nodepool ${HOSTED_CLUSTER_NAME} --replicas ${HYPERSHIFT_NODE_COUNT}

# Wait for agent installation to get completed
echo "$(date) Approved the agents, waiting for the installation to get completed on them"
oc wait --all=true agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster --timeout=45m

# Download hosted cluster kubeconfig
echo "$(date) Setup guest_kubeconfig"
hypershift create kubeconfig --namespace=${CLUSTERS_NAMESPACE} --name=${HOSTED_CLUSTER_NAME} >${SHARED_DIR}/guest_kubeconfig

# Waiting for compute nodes to attach (max: 30 min)
for ((i=60; i>=1; i--)); do
  node_count=$(oc get no --kubeconfig=${SHARED_DIR}/guest_kubeconfig --no-headers | wc -l)
  if [ "$node_count" -eq $HYPERSHIFT_NODE_COUNT ]; then
    echo "Compute nodes attached"
    break
  else
    echo "Waiting for Compute nodes to join..., $i retries left"
  fi
  sleep 30
done

# Waiting for compute nodes to be ready (max: 12 min)
for ((i=30; i>=1; i--)); do
  not_ready_count=$(oc get no --kubeconfig=${SHARED_DIR}/guest_kubeconfig --no-headers | awk '{print $2}' | grep -v 'Ready' | wc -l)
  if [ "$not_ready_count" -eq 0 ]; then
    echo "All Compute nodes are Ready"
    break
  else
    echo "Waiting for Compute nodes to be Ready..., $i retries left"
  fi
  sleep 25
done