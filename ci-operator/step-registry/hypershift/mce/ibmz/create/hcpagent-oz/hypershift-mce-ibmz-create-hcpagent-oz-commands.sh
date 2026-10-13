#!/bin/bash

set -x
set -e

# Target the management cluster before any oc call
echo "$(date) Targeting management cluster kubeconfig"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# --- Step 0: Download and install the hcp CLI ---
echo "$(date) Installing hcp CLI"
mkdir -p /tmp/hcp_cli
downloadURL=$(oc get ConsoleCLIDownload hcp-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
curl -k --output /tmp/hcp.tar.gz ${downloadURL}
tar -xvf /tmp/hcp.tar.gz -C /tmp/hcp_cli
chmod +x /tmp/hcp_cli/hcp
export PATH=$PATH:/tmp/hcp_cli
hcp version

# Installing required tools
mkdir -p /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
curl -L https://github.com/mikefarah/yq/releases/download/v4.31.2/yq_linux_amd64 -o /tmp/bin/yq && chmod +x /tmp/bin/yq
export PATH=$PATH:/tmp/bin

# --- Step 1: Prepare management cluster and create the HCP Agent hosted cluster ---

# Enable wildcard DNS routes so guest *.apps routes resolve through the management ingress
oc patch ingresscontroller -n openshift-ingress-operator default \
  --type=json \
  -p '[{ "op": "add", "path": "/spec/routeAdmission", "value": {"wildcardPolicy": "WildcardsAllowed"}}]'

set +x
# Extract the management cluster pull secret for use when provisioning the hosted cluster
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
cp /tmp/.dockerconfigjson /tmp/pull-secret

# Merge brew-token if present
brew_token_file="${AGENT_IBMZ_CREDENTIALS}/brew-token"
if [[ -f "${brew_token_file}" ]]; then
  cat /tmp/.dockerconfigjson | jq --arg brew_token "$(cat ${brew_token_file})" '.auths += {"brew.registry.redhat.io": {"auth": $brew_token}}' > /tmp/pull-secret
fi
PULL_SECRET_FILE=/tmp/pull-secret
set -x

# Hosted cluster identity and namespace — derived directly from the management node IP
NODE_IP=$(oc get nodes -o wide --no-headers 2>/dev/null \
  | awk '{print $6}' | grep -v '^$' | head -1)
echo "$(date) Detected management cluster node IP: ${NODE_IP}"

if [[ "${NODE_IP}" == 192.168.126.* ]]; then
  HC_NAME=hcpagent-oz-ci-0
  HC_NS=hcpagent-oz-ci-0-ns
  MGMT_CLUSTER_LEASE=3-0
elif [[ "${NODE_IP}" == 192.168.1.* ]]; then
  HC_NAME=hcpagent-oz-ci-1
  HC_NS=hcpagent-oz-ci-1-ns
  MGMT_CLUSTER_LEASE=3-1
elif [[ "${NODE_IP}" == 192.168.2.* ]]; then
  HC_NAME=hcpagent-oz-ci-2
  HC_NS=hcpagent-oz-ci-2-ns
  MGMT_CLUSTER_LEASE=3-2
elif [[ "${NODE_IP}" == 192.168.3.* ]]; then
  HC_NAME=hcpagent-oz-ci-3
  HC_NS=hcpagent-oz-ci-3-ns
  MGMT_CLUSTER_LEASE=3-3
else
  echo "$(date) ERROR: Unrecognised node IP subnet '${NODE_IP}', expected 192.168.126.x, 192.168.1.x, 192.168.2.x, or 192.168.3.x"
  exit 1
fi

echo "$(date) Using HC_NAME=${HC_NAME}, HC_NS=${HC_NS}"
MGMT_HOST_IP=10.0.1.15
echo "$(date) LPAR host IP: ${MGMT_HOST_IP}"

# --- Derive the fixed NodePort from the lease ---
if [[ "${MGMT_CLUSTER_LEASE}" == "3-0" ]]; then
  FIXED_NODEPORT=31130
elif [[ "${MGMT_CLUSTER_LEASE}" == "3-1" ]]; then
  FIXED_NODEPORT=31131
elif [[ "${MGMT_CLUSTER_LEASE}" == "3-2" ]]; then
  FIXED_NODEPORT=31132
elif [[ "${MGMT_CLUSTER_LEASE}" == "3-3" ]]; then
  FIXED_NODEPORT=31133
else
  echo "$(date) ERROR: unknown MGMT_CLUSTER_LEASE '${MGMT_CLUSTER_LEASE}'"
  exit 1
fi
echo "$(date) Fixed NodePort for lease ${MGMT_CLUSTER_LEASE}: ${FIXED_NODEPORT}"

hcp_ns="${HC_NS}-${HC_NAME}"
BASE_DOMAIN="phc-cicd.cis.ibm.net"

# InfraEnv SSH key
ssh_key_file="${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-pub-key"
if [[ ! -f "${ssh_key_file}" ]]; then
  ssh_key_file="${AGENT_IBMZ_CREDENTIALS}/ssh-publickey"
fi
ssh_key=$(cat "${ssh_key_file}")
export ssh_key

# Creating cluster imageset
cat <<EOF | oc create -f - || true
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: img-${hcp_ns}-appsub
spec:
  releaseImage: ${OCP_IMAGE_MULTI}
EOF

# Creating metal3 Provisioning resource if missing
if ! oc get provisioning provisioning-configuration &> /dev/null; then
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

# Applying mirror config
echo "$(date) Applying mirror config"
cat <<EOF | oc create -f - || true
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
        location = "quay.io:443/acm-d"
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
if [ -z "${OCP_IMAGE_MULTI:-}" ]; then
  echo "OCP_IMAGE_MULTI is required" >&2
  exit 1
fi
if ! RELEASE_INFO=$(oc adm release info "${OCP_IMAGE_MULTI}" --output=json); then
  echo "Failed to inspect release image ${OCP_IMAGE_MULTI}" >&2
  exit 1
fi
if ! RELEASE_VERSION=$(echo "${RELEASE_INFO}" | jq -er '.metadata.version // empty'); then
  echo "Release image ${OCP_IMAGE_MULTI} has no metadata.version" >&2
  exit 1
fi
CLUSTER_VERSION=$(echo "${RELEASE_VERSION}" | cut -d '.' -f 1,2)

if ! MACHINE_OS_IMAGE=$(oc adm release info \
  --image-for=machine-os-images \
  --filter-by-os=linux/amd64 \
  "${OCP_IMAGE_MULTI}"); then
  echo "Failed to resolve machine-os-images from ${OCP_IMAGE_MULTI}" >&2
  exit 1
fi

if ! COREOS_STREAM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/coreos-stream.XXXXXX"); then
  echo "Failed to create a temporary directory for coreos-stream.json" >&2
  exit 1
fi
COREOS_STREAM_JSON="${COREOS_STREAM_DIR}/coreos-stream.json"
if ! oc image extract "${MACHINE_OS_IMAGE}" \
  --path="/coreos/coreos-stream.json:${COREOS_STREAM_DIR}" \
  --registry-config=/etc/ci-pull-credentials/.dockerconfigjson \
  --filter-by-os=linux/amd64 \
  --confirm; then
  echo "Failed to extract /coreos/coreos-stream.json from ${MACHINE_OS_IMAGE}" >&2
  exit 1
fi
if [ ! -s "${COREOS_STREAM_JSON}" ]; then
  echo "${MACHINE_OS_IMAGE} does not contain /coreos/coreos-stream.json" >&2
  exit 1
fi
if ! OS_IMAGE_VERSION=$(jq -er '.architectures.s390x.artifacts.metal.release // empty' "${COREOS_STREAM_JSON}"); then
  echo "No RHCOS metal release found for s390x in ${MACHINE_OS_IMAGE}" >&2
  exit 1
fi
if ! OS_IMAGE_URL=$(jq -er '.architectures.s390x.artifacts.metal.formats.iso.disk.location // empty' "${COREOS_STREAM_JSON}"); then
  echo "No RHCOS metal ISO URL found for s390x in ${MACHINE_OS_IMAGE}" >&2
  exit 1
fi

echo "$(date) Creating AgentServiceConfig"
cat <<EOF | oc apply -f -
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
    - openshiftVersion: "${CLUSTER_VERSION}"
      version: "${OS_IMAGE_VERSION}"
      url: "${OS_IMAGE_URL}"
      cpuArchitecture: s390x
EOF

oc wait --timeout=5m --for=condition=DeploymentsHealthy agentserviceconfig agent
echo "$(date) AgentServiceConfig is ready"

# Creating agent hosted cluster manifests
echo "$(date) Creating agent hosted cluster manifests"
oc create ns "${HC_NS}" || true
oc create ns "${hcp_ns}" || true
mkdir -p /tmp/hc-manifests

HC_MANIFEST="/tmp/hc-manifests/cluster-agent.yaml"
hcp create cluster agent \
  --name=${HC_NAME} \
  --pull-secret="${PULL_SECRET_FILE}" \
  --agent-namespace=${hcp_ns} \
  --base-domain=${BASE_DOMAIN} \
  --api-server-address=api.${HC_NAME}.${BASE_DOMAIN} \
  --ssh-key=${ssh_key_file} \
  --control-plane-availability-policy SingleReplica \
  --infra-availability-policy SingleReplica \
  --namespace=${HC_NS} \
  --release-image=${OCP_IMAGE_MULTI} \
  --render-sensitive --render > "${HC_MANIFEST}"

echo "$(date) Rendered HCP agent manifests to ${HC_MANIFEST}"

echo "$(date) Applying HCP agent manifests"
oc apply -f "${HC_MANIFEST}"

# --- Pin the kube-apiserver Service NodePort to FIXED_NODEPORT ---
KAPI_SVC_NS="${hcp_ns}"
KAPI_SVC_NAME="kube-apiserver"

echo "$(date) Waiting for Service ${KAPI_SVC_NAME} to appear in ${KAPI_SVC_NS}"
for i in {1..60}; do
  if oc get svc "${KAPI_SVC_NAME}" -n "${KAPI_SVC_NS}" &>/dev/null; then
    echo "$(date) Service ${KAPI_SVC_NAME} found (attempt ${i})"
    break
  fi
  echo "$(date) Service not yet present, waiting 10s... (${i}/60)"
  sleep 10
done

if ! oc get svc "${KAPI_SVC_NAME}" -n "${KAPI_SVC_NS}" &>/dev/null; then
  echo "$(date) ERROR: Service ${KAPI_SVC_NAME} did not appear within 10 minutes"
  exit 1
fi

echo "$(date) Patching ${KAPI_SVC_NAME} port[0].nodePort → ${FIXED_NODEPORT}"
oc patch svc "${KAPI_SVC_NAME}" -n "${KAPI_SVC_NS}" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${FIXED_NODEPORT}}]"
echo "$(date) NodePort pinned to ${FIXED_NODEPORT} on Service ${KAPI_SVC_NAME}"

oc wait --timeout=45m --for=condition=Available --namespace="${HC_NS}" hostedclusters.hypershift.openshift.io/"${HC_NAME}"
echo "$(date) Agent hosted cluster is available"

# Applying InfraEnv
echo "$(date) Applying InfraEnv"
cat <<EOF | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${HC_NAME}
  namespace: ${hcp_ns}
spec:
  cpuArchitecture: s390x
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: "${ssh_key}"
  ignitionConfigOverride: '{"ignition":{"version":"3.2.0"},"storage":{"files":[{"path":"/etc/containers/policy.json","mode":420,"overwrite":true,"contents":{"source":"data:text/plain;charset=utf-8;base64,ewogICAgImRlZmF1bHQiOiBbCiAgICAgICAgewogICAgICAgICAgICAidHlwZSI6ICJpbnNlY3VyZUFjY2VwdEFueXRoaW5nIgogICAgICAgIH0KICAgIF0sCiAgICAidHJhbnNwb3J0cyI6CiAgICAgICAgewogICAgICAgICAgICAiZG9ja2VyLWRhZW1vbiI6CiAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgIiI6IFt7InR5cGUiOiJpbnNlY3VyZUFjY2VwdEFueXRoaW5nIn1dCiAgICAgICAgICAgICAgICB9CiAgICAgICAgfQp9"}}]}}'
EOF

# Waiting for discovery ISO to become ready
echo "$(date) Waiting for InfraEnv discovery ISO to be created..."
oc wait --timeout=10m --for=condition=ImageCreated --namespace=${hcp_ns} infraenv/${HC_NAME}
echo "$(date) Discovery ISO is ready"

# Retrieve guest cluster kubeconfig
echo "$(date) Retrieving guest cluster kubeconfig"
hcp create kubeconfig --name "${HC_NAME}" --namespace "${HC_NS}" > "${SHARED_DIR}/nested_kubeconfig"

# Persist management cluster kubeconfig
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/mgmt_kubeconfig"

# Persist cluster identity for downstream test steps
echo -n "${HC_NAME}" > "${SHARED_DIR}/cluster-name"
echo -n "${HC_NS}"   > "${SHARED_DIR}/cluster-namespace"

# Patch nested kubeconfig server URL to reach through LPAR HAProxy
CLSTR_NAME=$(oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" config view -o jsonpath='{.clusters[0].name}')
oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" config set-cluster "${CLSTR_NAME}" \
  --server="https://${MGMT_HOST_IP}:${FIXED_NODEPORT}" \
  --insecure-skip-tls-verify=true
echo "$(date) Patched nested_kubeconfig server → https://${MGMT_HOST_IP}:${FIXED_NODEPORT}"

# Verify the fixed NodePort is reachable via the LPAR HAProxy
echo "$(date) Probing kube-apiserver via LPAR HAProxy at ${MGMT_HOST_IP}:${FIXED_NODEPORT}"
for i in {1..10}; do
  READYZ=$(curl -sk --connect-timeout 5 "https://${MGMT_HOST_IP}:${FIXED_NODEPORT}/readyz" 2>/dev/null || true)
  echo "$(date) [probe ${i}/10] /readyz: ${READYZ}"
  [[ "${READYZ}" == "ok" ]] && break
  sleep 10
done

echo "$(date) Successfully completed the Hosted Cluster creation with type agent in OZ."

echo "$(date) Pods in hcp namespace ${hcp_ns}"
oc get pods -n "${hcp_ns}"
