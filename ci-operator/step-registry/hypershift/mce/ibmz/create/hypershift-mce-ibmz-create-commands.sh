#!/bin/bash

set -x
# Agent Service Config parameters
export DB_VOLUME_SIZE="10Gi"
export FS_VOLUME_SIZE="10Gi"
export ARCH="s390x"
export OCP_RELEASE_VERSION=$(curl -s "$OCP_RELEASE_FILE_URL" | awk '/machine-os / { print $2 }')

# Hosted Control Plane parameters
CLUSTERS_NAMESPACE="clusters"
HOSTED_CLUSTER_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HOSTED_CLUSTER_NAME
export HOSTED_CONTROL_PLANE_NAMESPACE="${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"
export MACHINE_CIDR=192.168.122.0/24


# InfraEnv configs
SSH_PUB_KEY_FILE="${AGENT_POWER_CREDENTIALS}/ssh-publickey"
SSH_PUB_KEY=$(cat ${SSH_PUB_KEY_FILE})
export SSH_PUB_KEY


# Creating cluster imageset
if ! oc get clusterimageset img"$OCP_HCP_RELEASE"-appsub &> /dev/null; then
  # If it doesn't exist, create it
  cat <<EOF | oc create -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: img$OCP_HCP_RELEASE-appsub
spec:
  releaseImage: quay.io/openshift-release-dev/ocp-release:$OCP_HCP_RELEASE
EOF
else
  echo "Resource img"$OCP_HCP_RELEASE"-appsub already exists. Skipping creation."
fi

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
downURL=$(oc get ConsoleCLIDownload hypershift-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for IBM Z")).href')
curl -k --output /tmp/hypershift.tar.gz ${downURL}
tar -xvf /tmp/hypershift.tar.gz -C /tmp/hypershift_cli
chmod +x /tmp/hypershift_cli/hypershift
export PATH=$PATH:/tmp/hypershift_cli


# Installing required tools
mkdir /tmp/bin
#curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
curl -L https://github.com/mikefarah/yq/releases/download/v4.31.2/yq_linux_s390x -o /tmp/bin/yq && chmod +x /tmp/bin/yq
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
brewToken="${AGENT_POWER_CREDENTIALS}/brew-token"
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
  nmStateConfigLabelSelector:
    matchLabels:
      infraenv: static-ip-s390x
  cpuArchitecture: $ARCH
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${SSH_PUB_KEY}
EOF



# Generating mac addresses
mac_addresses=()
for ((i = 0; i < $HYPERSHIFT_NODE_COUNT; i++)); do
    mac_addresses+=("$(printf "fa:16:3e:%02x:%02x:%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))")
done

# Creating NMStateconfigs for static IP configuration

for ((i = 0; i < $HYPERSHIFT_NODE_COUNT; i++)); do
    cat <<EOF | oc create -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: NMStateConfig
metadata:
  name: "static-ip-nmstate-config-$i"
  namespace: ${HOSTED_CONTROL_PLANE_NAMESPACE}
  labels:
    infraenv: static-ip-s390x
spec:
  config:
    interfaces:
      - name: eth0
        type: ethernet
        state: up
        mac-address: ${mac_addresses[i]}
        ipv4:
          enabled: true
          address:
            - ip: ${IP_ADDRESSES[i]}
              prefix-length: 16
          dhcp: false
    routes:
      config:
        - destination: 0.0.0.0/0
          next-hop-address: 172.23.0.1
          next-hop-interface: eth0
          table-id: 254
    dns-resolver:
      config:
        server:
          - 172.23.235.4

  interfaces:
    - name: "eth0"
      macAddress: ${mac_addresses[i]}
EOF
echo "Created static-ip-nmstate-config-$i"
done



HOSTED_CLUSTER_API_SERVER=$(oc get service kube-apiserver -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.loadBalancer.ingress[].hostname')

# Waiting for discovery iso file to ready
oc wait --timeout=10m --for=condition=ImageCreated --namespace=${HOSTED_CONTROL_PLANE_NAMESPACE} infraenv/${HOSTED_CLUSTER_NAME}
echo "$(date) ISO Download url ready"

# Downloading required images

INITRD_URL=$(oc get infraenv/${HOSTED_CLUSTER_NAME} -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.bootArtifacts.initrd') 
KERNEL_URL=$(oc get infraenv/${HOSTED_CLUSTER_NAME} -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.bootArtifacts.kernel')
ROOTFS_URL=$(oc get infraenv/${HOSTED_CLUSTER_NAME} -n ${HOSTED_CONTROL_PLANE_NAMESPACE} -o json | jq -r '.status.bootArtifacts.rootfs')

# Login to machine where the VMs should boot

mkdir -p /var/lib/libvirt/images/pxeboot 
curl -k -L -o /var/lib/libvirt/images/pxeboot "$INITRD_URL"
curl -k -L -o /var/lib/libvirt/images/pxeboot "$KERNEL_URL"

# Setup httpd on any VM other than machine where VMs are getting booted  and down load rootfs on /var/www/html


# Create qemu 
for ((i = 0; i < $HYPERSHIFT_BASEDOMAIN ; i++)); do
qemu-img create -f qcow2 /home/libvirt/images/agent$i.qcow2 100G
done

# Boot agents 
for ((i = 0; i < $HYPERSHIFT_BASEDOMAIN ; i++)); do
  virt-install   --name "agent-1"   --autostart   --ram=16384   --cpu host   --vcpus=4   --location "/var/lib/libvirt/images/pxeboot/,kernel=kernel.img,initrd=initrd.img"   --disk /home/libvirt/images/agent$i.qcow2   --network network:default,mac=${mac_addresses[i]}   --graphics none   --noautoconsole   --wait=-1   --extra-args "rd.neednet=1 nameserver=172.23.0.1   coreos.live.rootfs_url=http://172.23.232.140:8080/rootfs.img random.trust_cpu=on rd.luks.options=discard ignition.firstboot ignition.platform.id=metal console=tty1 console=ttyS1,115200n8 coreos.inst.persistent-kargs=console=tty1 console=ttyS1,115200n8"
done

# Logout from machine

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
echo "$(date) Setup guest_kubeconfig"
hypershift create kubeconfig --namespace=${CLUSTERS_NAMESPACE} --name=${HOSTED_CLUSTER_NAME} >${HOME}/guest_kubeconfig

