#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Export environment variables
#=====================
export ACM_SPOKE_ARCH_TYPE
export BASE_DOMAIN
export ACM_SPOKE_WORKER_TYPE
export ACM_SPOKE_CP_TYPE
export ACM_SPOKE_WORKER_REPLICAS
export ACM_SPOKE_CP_REPLICAS
export ACM_SPOKE_CLUSTER_NAME_PREFIX
export ACM_SPOKE_CLUSTER_REGION="${MANAGED_CLUSTER_LEASED_RESOURCE}"
export ACM_SPOKE_NETWORK_TYPE
export ACM_SPOKE_INSTALL_TIMEOUT_MINUTES
export ACM_SPOKE_CLUSTER_INITIAL_VERSION


#=====================
# Validate required files
#=====================
if [[ ! -f "${SHARED_DIR}/metadata.json" ]]; then
    echo "[ERROR] Required file not found: ${SHARED_DIR}/metadata.json" >&2
    exit 1
fi

#=====================
# Helper functions
#=====================
Need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[FATAL] '$1' not found" >&2
        exit 1
    }
}

JsonGet() {
    oc -n "${1}" get "${2}" "${3}" -o json
}
Need base64

#=====================
# Generate cluster name
#=====================
typeset hub_cluster_name
hub_cluster_name="$(jq -r '.clusterName' "${SHARED_DIR}/metadata.json")"
if [[ -z "${hub_cluster_name}" ]]; then
    echo "[ERROR] Could not extract hub cluster name from metadata.json" >&2
    exit 1
fi

if [[ -z "${ACM_SPOKE_CLUSTER_NAME_PREFIX}" ]]; then
    echo "[ERROR] ACM_SPOKE_CLUSTER_NAME_PREFIX is not set" >&2
    exit 1
fi

typeset suffix
suffix="$(echo -n "${hub_cluster_name}" | sha1sum | cut -c1-5)"
if [[ -z "${suffix}" ]]; then
    echo "[ERROR] Failed to generate cluster name suffix" >&2
    exit 1
fi

export ACM_SPOKE_CLUSTER_NAME="${ACM_SPOKE_CLUSTER_NAME_PREFIX}-${suffix}"
if [[ -z "${ACM_SPOKE_CLUSTER_NAME}" ]]; then
    echo "[ERROR] Generated cluster name is empty" >&2
    exit 1
fi

# Write cluster name to file
echo "${ACM_SPOKE_CLUSTER_NAME}" > "${SHARED_DIR}/managed-cluster-name"

# Verify file was created and contains expected content
if [[ ! -f "${SHARED_DIR}/managed-cluster-name" ]]; then
    echo "[ERROR] Failed to create cluster name file: ${SHARED_DIR}/managed-cluster-name" >&2
    exit 1
fi

if [[ ! -r "${SHARED_DIR}/managed-cluster-name" ]]; then
    echo "[ERROR] Cluster name file is not readable: ${SHARED_DIR}/managed-cluster-name" >&2
    exit 1
fi

typeset read_cluster_name
read_cluster_name="$(cat "${SHARED_DIR}/managed-cluster-name")"
if [[ -z "${read_cluster_name}" ]]; then
    echo "[ERROR] Cluster name file is empty: ${SHARED_DIR}/managed-cluster-name" >&2
    exit 1
fi

if [[ "${read_cluster_name}" != "${ACM_SPOKE_CLUSTER_NAME}" ]]; then
    echo "[ERROR] Cluster name mismatch. Expected: '${ACM_SPOKE_CLUSTER_NAME}', Found: '${read_cluster_name}'" >&2
    exit 1
fi

echo "[INFO] Cluster name '${ACM_SPOKE_CLUSTER_NAME}' written successfully to ${SHARED_DIR}/managed-cluster-name"

#=====================
# Create namespace
#=====================
echo "[INFO] Creating namespace '${ACM_SPOKE_CLUSTER_NAME}'"
oc create namespace "${ACM_SPOKE_CLUSTER_NAME}" --dry-run=client -o yaml | oc apply -f -
oc project "${ACM_SPOKE_CLUSTER_NAME}"

#=====================
# Create ManagedClusterSet
#=====================
echo "[INFO] Creating ManagedClusterSet '${ACM_SPOKE_CLUSTER_NAME}-set'"
oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: ${ACM_SPOKE_CLUSTER_NAME}-set
  namespace: ${ACM_SPOKE_CLUSTER_NAME}
spec: {}
EOF

#=====================
# Create ManagedClusterSetBinding
#=====================
echo "[INFO] Creating ManagedClusterSetBinding '${ACM_SPOKE_CLUSTER_NAME}-set'"
oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${ACM_SPOKE_CLUSTER_NAME}-set
  namespace: ${ACM_SPOKE_CLUSTER_NAME}
spec:
  clusterSet: ${ACM_SPOKE_CLUSTER_NAME}-set
EOF

#=====================
# Create AWS credentials secret
#=====================
echo "[INFO] Creating AWS credentials secret"
oc -n "${ACM_SPOKE_CLUSTER_NAME}" create secret generic acm-aws-secret \
    --type=Opaque \
    --from-file=aws_access_key_id=<( set +x
        printf '%s' "$(
            cat "${CLUSTER_PROFILE_DIR}/.awscred" |
            sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q'
        )"
      true ) \
    --from-file=aws_secret_access_key=<( set +x
        printf '%s' "$(
            cat "${CLUSTER_PROFILE_DIR}/.awscred" |
            sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q'
        )"
      true ) \
    --dry-run=client -o yaml | oc apply -f -

oc label secret acm-aws-secret \
    cluster.open-cluster-management.io/type=aws \
    cluster.open-cluster-management.io/credentials="" \
    -n "${ACM_SPOKE_CLUSTER_NAME}" --overwrite \
    --dry-run=client -o yaml | oc apply -f -

#=====================
# Create pull-secret
#=====================
echo "[INFO] Creating pull-secret"
oc -n "${ACM_SPOKE_CLUSTER_NAME}" create secret generic pull-secret \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="${CLUSTER_PROFILE_DIR}/config.json" \
    --dry-run=client -o yaml | oc apply -f -

#=====================
# Create SSH public key secret
#=====================
echo "[INFO] Creating SSH public key secret"
oc -n "${ACM_SPOKE_CLUSTER_NAME}" create secret generic ssh-public-key \
    --type=Opaque \
    --from-file=ssh-publickey="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
    --dry-run=client -o yaml | oc apply -f -

#=====================
# Create SSH private key secret
#=====================
echo "[INFO] Creating SSH private key secret"
oc -n "${ACM_SPOKE_CLUSTER_NAME}" create secret generic ssh-private-key \
    --type=Opaque \
    --from-file=ssh-privatekey="${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    --dry-run=client -o yaml | oc apply -f -

#=====================
# Create install-config
#=====================
echo "[INFO] Creating install-config"
typeset install_config_file="/tmp/install-config.yaml"

cat > "${install_config_file}" <<EOF
apiVersion: v1
metadata:
  name: ${ACM_SPOKE_CLUSTER_NAME}
baseDomain: ${BASE_DOMAIN}
controlPlane:
  architecture: ${ACM_SPOKE_ARCH_TYPE}
  hyperthreading: Enabled
  name: master
  replicas: ${ACM_SPOKE_CP_REPLICAS}
  platform:
    aws:
      type: ${ACM_SPOKE_CP_TYPE}
compute:
- hyperthreading: Enabled
  architecture: ${ACM_SPOKE_ARCH_TYPE}
  name: 'worker'
  replicas: ${ACM_SPOKE_WORKER_REPLICAS}
  platform:
    aws:
      type: ${ACM_SPOKE_WORKER_TYPE}
networking:
  networkType: ${ACM_SPOKE_NETWORK_TYPE}
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: ${ACM_SPOKE_CLUSTER_REGION}
sshKey: |-
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

#=====================
# Create install-config secret
#=====================
echo "[INFO] Creating install-config secret"
oc -n "${ACM_SPOKE_CLUSTER_NAME}" create secret generic install-config \
    --type Opaque \
    --from-file install-config.yaml="${install_config_file}" \
    --dry-run=client -o yaml --save-config | oc apply -f -

#=====================
# Resolve cluster image set
#=====================
echo "[INFO] Resolving cluster image set for version '${ACM_SPOKE_CLUSTER_INITIAL_VERSION}'"
typeset cluster_imageset_name
cluster_imageset_name="$(
    oc get clusterimagesets.hive.openshift.io \
        -o jsonpath='{.items[*].metadata.name}' \
        | tr ' ' '\n' \
        | grep "^img${ACM_SPOKE_CLUSTER_INITIAL_VERSION}\." \
        | sort -V \
        | tail -n 1
)"

if [[ -z "${cluster_imageset_name}" ]]; then
    echo "[ERROR] No cluster image set found for version '${ACM_SPOKE_CLUSTER_INITIAL_VERSION}'" >&2
    exit 1
fi

# Verify the ClusterImageSet exists and is accessible
if ! oc get clusterimageset "${cluster_imageset_name}" &> /dev/null; then
    echo "[ERROR] ClusterImageSet '${cluster_imageset_name}' not found or not accessible" >&2
    exit 1
fi

echo "[INFO] Using cluster image set: ${cluster_imageset_name}"

# Get release image for logging purposes (Hive will resolve it from imageSetRef)
typeset ocp_release_image
ocp_release_image="$(
    oc get clusterimageset "${cluster_imageset_name}" \
        -o jsonpath='{.spec.releaseImage}' 2>/dev/null || echo ""
)"

if [[ -n "${ocp_release_image}" ]]; then
    echo "[INFO] Cluster image set release image: ${ocp_release_image}"
fi

#=====================
# Create ClusterDeployment
#=====================
echo "[INFO] Creating ClusterDeployment '${ACM_SPOKE_CLUSTER_NAME}'"
typeset cluster_deployment_file="/tmp/clusterdeployment.yaml"

cat > "${cluster_deployment_file}" <<EOF
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: ${ACM_SPOKE_CLUSTER_NAME}
  namespace: ${ACM_SPOKE_CLUSTER_NAME}
  labels:
    cloud: 'AWS'
    region: '${ACM_SPOKE_CLUSTER_REGION}'
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: '${ACM_SPOKE_CLUSTER_NAME}-set'
spec:
  baseDomain: ${BASE_DOMAIN}
  clusterName: ${ACM_SPOKE_CLUSTER_NAME}
  controlPlaneConfig:
    servingCertificates: {}
  platform:
    aws:
      region: ${ACM_SPOKE_CLUSTER_REGION}
      credentialsSecretRef:
        name: acm-aws-secret
  pullSecretRef:
    name: pull-secret
  installAttemptsLimit: 1
  provisioning:
    installConfigSecretRef:
      name: install-config
    imageSetRef:
      name: ${cluster_imageset_name}
    sshPrivateKeyRef:
      name: ssh-private-key
EOF

oc apply -f "${cluster_deployment_file}"

#=====================
# Create ManagedCluster
#=====================
echo "[INFO] Creating ManagedCluster '${ACM_SPOKE_CLUSTER_NAME}'"
typeset managed_cluster_file="/tmp/managed_cluster.yaml"

cat > "${managed_cluster_file}" <<EOF
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${ACM_SPOKE_CLUSTER_NAME}
  labels:
    name: ${ACM_SPOKE_CLUSTER_NAME}
    cloud: Amazon
    region: ${ACM_SPOKE_CLUSTER_REGION}
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: ${ACM_SPOKE_CLUSTER_NAME}-set
spec:
  hubAcceptsClient: true
EOF

oc apply -f "${managed_cluster_file}"

#=====================
# Create KlusterletAddonConfig
#=====================
echo "[INFO] Creating KlusterletAddonConfig '${ACM_SPOKE_CLUSTER_NAME}'"
typeset klusterlet_addon_config_file="/tmp/klusterletaddonconfig.yaml"

cat > "${klusterlet_addon_config_file}" <<EOF
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: ${ACM_SPOKE_CLUSTER_NAME}
  namespace: ${ACM_SPOKE_CLUSTER_NAME}
spec:
  clusterName: ${ACM_SPOKE_CLUSTER_NAME}
  clusterNamespace: ${ACM_SPOKE_CLUSTER_NAME}
  clusterLabels:
    cloud: Amazon
    vendor: OpenShift
  applicationManager:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
  certPolicyController:
    enabled: true
EOF

oc apply -f "${klusterlet_addon_config_file}"

#=====================
# Wait for cluster provisioning
#=====================
echo "[INFO] Waiting for ClusterDeployment to reach status Provisioned=True (timeout=${ACM_SPOKE_INSTALL_TIMEOUT_MINUTES}m)"
oc -n "${ACM_SPOKE_CLUSTER_NAME}" wait "ClusterDeployment/${ACM_SPOKE_CLUSTER_NAME}" \
    --for condition=Provisioned \
    --timeout "${ACM_SPOKE_INSTALL_TIMEOUT_MINUTES}m"

#=====================
# Final status check
#=====================
echo "[INFO] Verifying cluster provisioning status"
typeset cd_json
cd_json="$(JsonGet "${ACM_SPOKE_CLUSTER_NAME}" clusterdeployment "${ACM_SPOKE_CLUSTER_NAME}")"

typeset provisioned
provisioned="$(echo "${cd_json}" | jq -r '
    .status.conditions[]?
    | select(.type=="Provisioned" and .status=="True")
    | .type
')"

if [[ "${provisioned}" == "Provisioned" ]]; then
    echo "[SUCCESS] ClusterDeployment status Provisioned is True. Installation complete."
else
    typeset stop_reason
    stop_reason="$(echo "${cd_json}" | jq -r '
        .status.conditions[]?
        | select(.type=="ProvisionStopped" and .status=="True")
        | .reason // "N/A"
    ')"
    echo "[FATAL] Installation failed or timed out. ProvisionStopped reason: ${stop_reason}" >&2
    exit 3
fi

#=====================
# Extract kubeconfig
#=====================
echo "[INFO] Extracting admin kubeconfig"
admin_kubeconfig_secret_name="$(
    oc -n "${ACM_SPOKE_CLUSTER_NAME}" get "ClusterDeployment/${ACM_SPOKE_CLUSTER_NAME}" \
        -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}'
)"

if [[ -z "${admin_kubeconfig_secret_name}" ]]; then
    echo "[ERROR] Failed to get admin kubeconfig secret name" >&2
    exit 1
fi

oc -n "${ACM_SPOKE_CLUSTER_NAME}" get "Secret/${admin_kubeconfig_secret_name}" \
    -o jsonpath='{.data.kubeconfig}' |
    base64 -d > "${SHARED_DIR}/managed-cluster-kubeconfig"

echo "[SUCCESS] Spoke cluster provisioning and ACM registration completed successfully."

#=====================
# Extract cluster metadata
#=====================
metadata_secret="$(
    oc -n "${ACM_SPOKE_CLUSTER_NAME}" get "ClusterDeployment/${ACM_SPOKE_CLUSTER_NAME}" \
        -o jsonpath='{.spec.clusterMetadata.metadataJSONSecretRef.name}'
)"

if [[ -z "${metadata_secret}" ]]; then
    echo "[WARN] metadataJSONSecretRef is not set; metadata.json may not exist for this cluster"
else
    if oc -n "${ACM_SPOKE_CLUSTER_NAME}" get secret "${metadata_secret}" >/dev/null 2>&1; then
        oc -n "${ACM_SPOKE_CLUSTER_NAME}" get secret "${metadata_secret}" \
            -o jsonpath='{.data.metadata\.json}' | base64 -d \
            > "${SHARED_DIR}/managed.cluster.metadata.json"
        echo "[INFO] Cluster metadata extracted successfully"
    else
        echo "[ERROR] Secret '${metadata_secret}' not found in namespace '${ACM_SPOKE_CLUSTER_NAME}'" >&2
    fi
fi
