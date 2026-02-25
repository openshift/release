#!/bin/bash
#
# ACM Spoke Cluster Installation Script
#
# This script provisions one or more OpenShift spoke clusters using
# Red Hat Advanced Cluster Management (ACM) and Hive ClusterDeployment.
#
# Features:
#   - Creates multiple spoke clusters based on ACM_SPOKE_CLUSTER_COUNT
#   - Each cluster uses a separate AWS region from MANAGED_CLUSTER_LEASED_RESOURCE
#   - Generates unique cluster names using hub cluster name hash
#   - Registers clusters with ACM hub using ManagedCluster resources
#   - Extracts kubeconfig and metadata for each provisioned cluster
#
# Leasing:
#   - MANAGED_CLUSTER_LEASED_RESOURCE contains one lease (region) per cluster
#   - For 3 clusters, expect 3 space-separated regions (e.g., "us-west-2 us-east-1 eu-west-1")
#   - The number of leases must match ACM_SPOKE_CLUSTER_COUNT
#
# Output Files (per cluster):
#   - managed-cluster-name-{N}         : Cluster name
#   - managed-cluster-kubeconfig-{N}   : Admin kubeconfig
#   - managed-cluster-metadata-{N}.json: Cluster metadata
#
# Prerequisites:
#   - Hub cluster with ACM installed
#   - Valid AWS credentials in cluster profile
#   - ClusterImageSet available for target OCP version
#   - Sufficient leases acquired for the number of clusters
#

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Export environment variables
#=====================
# These variables are passed from the CI step registry ref.yaml
# and define the spoke cluster configuration
export ACM_SPOKE_ARCH_TYPE                # CPU architecture (amd64, arm64)
export BASE_DOMAIN                        # Base DNS domain for cluster
export ACM_SPOKE_WORKER_TYPE              # AWS instance type for workers
export ACM_SPOKE_CP_TYPE                  # AWS instance type for control plane
export ACM_SPOKE_WORKER_REPLICAS          # Number of worker nodes
export ACM_SPOKE_CP_REPLICAS              # Number of control plane nodes
export ACM_SPOKE_CLUSTER_NAME_PREFIX      # Prefix for cluster names
export ACM_SPOKE_NETWORK_TYPE             # Network plugin (OVNKubernetes, OpenShiftSDN)
export ACM_SPOKE_INSTALL_TIMEOUT_MINUTES  # Timeout for cluster provisioning
export ACM_SPOKE_CLUSTER_INITIAL_VERSION  # Target OCP version (e.g., 4.14)
export ACM_SPOKE_CLUSTER_COUNT="${ACM_SPOKE_CLUSTER_COUNT:-1}"  # Number of clusters to create

#=====================
# Parse leased resources into array
#=====================
# MANAGED_CLUSTER_LEASED_RESOURCE contains one AWS region per cluster lease
# Format: space-separated list of regions (e.g., "us-west-2 us-east-1 eu-west-1")
# Each cluster will be deployed to its corresponding region from this list
typeset -a cluster_regions=()
if [[ -n "${MANAGED_CLUSTER_LEASED_RESOURCE:-}" ]]; then
    # Split the space-separated string into an array
    read -ra cluster_regions <<< "${MANAGED_CLUSTER_LEASED_RESOURCE}"
else
    echo "[ERROR] MANAGED_CLUSTER_LEASED_RESOURCE is not set or empty" >&2
    exit 1
fi

echo "[INFO] Parsed ${#cluster_regions[@]} region(s) from leases: ${cluster_regions[*]}"

#=====================
# Validate required files
#=====================
# The metadata.json file contains hub cluster information needed
# to generate unique spoke cluster names
if [[ ! -f "${SHARED_DIR}/metadata.json" ]]; then
    echo "[ERROR] Required file not found: ${SHARED_DIR}/metadata.json" >&2
    exit 1
fi

#=====================
# Validate cluster count
#=====================
# Ensure cluster count is a valid positive integer
if [[ ! "${ACM_SPOKE_CLUSTER_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERROR] ACM_SPOKE_CLUSTER_COUNT must be a positive integer, got: '${ACM_SPOKE_CLUSTER_COUNT}'" >&2
    exit 1
fi

# Limit maximum clusters to prevent resource exhaustion
if [[ "${ACM_SPOKE_CLUSTER_COUNT}" -gt 3 ]]; then
    echo "[ERROR] ACM_SPOKE_CLUSTER_COUNT exceeds maximum of 3, got: '${ACM_SPOKE_CLUSTER_COUNT}'" >&2
    exit 1
fi

#=====================
# Validate lease count matches cluster count
#=====================
# Each cluster requires exactly one lease (region)
# The number of leases must match the requested cluster count
if [[ "${#cluster_regions[@]}" -ne "${ACM_SPOKE_CLUSTER_COUNT}" ]]; then
    echo "[ERROR] Lease count mismatch: got ${#cluster_regions[@]} lease(s) but ACM_SPOKE_CLUSTER_COUNT=${ACM_SPOKE_CLUSTER_COUNT}" >&2
    echo "[ERROR] Each cluster requires exactly one lease. Ensure 'count' in leases configuration matches ACM_SPOKE_CLUSTER_COUNT" >&2
    exit 1
fi

echo "[INFO] Lease validation passed: ${ACM_SPOKE_CLUSTER_COUNT} cluster(s) with ${#cluster_regions[@]} lease(s)"

#=====================
# Helper functions
#=====================

# Need - Verify that a required command is available
# Arguments:
#   $1 - Command name to check
# Exits with error if command is not found
Need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[FATAL] '$1' not found" >&2
        exit 1
    }
    true
}

# JsonGet - Retrieve a Kubernetes resource as JSON
# Arguments:
#   $1 - Namespace
#   $2 - Resource type
#   $3 - Resource name
# Returns: JSON representation of the resource
JsonGet() {
    oc -n "${1}" get "${2}" "${3}" -o json
}

# Verify required CLI tools are available
Need oc
Need jq
Need base64

#=====================
# Get hub cluster name for suffix generation
#=====================
# Extract the hub cluster name from metadata.json
# This is used to generate unique spoke cluster names
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

#=====================
# Resolve cluster image set (once for all clusters)
#=====================
# Find the latest ClusterImageSet matching the target OCP version
# ClusterImageSets are named like: img4.14.0-x86_64, img4.14.1-x86_64, etc.
echo "[INFO] Resolving cluster image set for version '${ACM_SPOKE_CLUSTER_INITIAL_VERSION}'"
typeset cluster_imageset_name
cluster_imageset_name="$(
    oc get clusterimagesets.hive.openshift.io \
        -o jsonpath='{.items[*].metadata.name}' |
        tr ' ' '\n' |
        grep "^img${ACM_SPOKE_CLUSTER_INITIAL_VERSION}\." |
        sort -V |
        tail -n 1
)"

if [[ -z "${cluster_imageset_name}" ]]; then
    echo "[ERROR] No cluster image set found for version '${ACM_SPOKE_CLUSTER_INITIAL_VERSION}'" >&2
    exit 1
fi

# Double-check that the ClusterImageSet resource exists
if ! oc get clusterimageset "${cluster_imageset_name}" &>/dev/null; then
    echo "[ERROR] ClusterImageSet '${cluster_imageset_name}' not found or not accessible" >&2
    exit 1
fi

echo "[INFO] Using cluster image set: ${cluster_imageset_name}"

# Log the release image URL for debugging purposes
typeset ocp_release_image
ocp_release_image="$(
    oc get clusterimageset "${cluster_imageset_name}" \
        -o jsonpath='{.spec.releaseImage}' 2>/dev/null || echo ""
)"

if [[ -n "${ocp_release_image}" ]]; then
    echo "[INFO] Cluster image set release image: ${ocp_release_image}"
fi

#=====================
# Generate unique cluster names
#=====================
# Create a base suffix from the hub cluster name hash (first 5 chars)
# This ensures spoke cluster names are unique per hub cluster
typeset base_suffix
base_suffix="$(echo -n "${hub_cluster_name}" | sha1sum | cut -c1-5)"
if [[ -z "${base_suffix}" ]]; then
    echo "[ERROR] Failed to generate cluster name base suffix" >&2
    exit 1
fi

# Build array of cluster names: {prefix}-{hash}-{index}
# Example: acm-spoke-a1b2c-1, acm-spoke-a1b2c-2, acm-spoke-a1b2c-3
typeset -a cluster_names=()
typeset unique_suffix=""
typeset cluster_name=""
for ((i = 1; i <= ACM_SPOKE_CLUSTER_COUNT; i++)); do
    unique_suffix="${base_suffix}-${i}"
    cluster_name="${ACM_SPOKE_CLUSTER_NAME_PREFIX}-${unique_suffix}"
    cluster_names+=("${cluster_name}")
done

echo "[INFO] Will create ${#cluster_names[@]} cluster(s):"
for ((i = 0; i < ${#cluster_names[@]}; i++)); do
    echo "[INFO]   Cluster $((i+1)): ${cluster_names[i]} -> Region: ${cluster_regions[i]}"
done

#=====================
# Write cluster names to individual files
#=====================
# Each cluster gets its own name file for use by subsequent steps
typeset cluster_index=0
typeset cluster_name_file=""
for cluster_name in "${cluster_names[@]}"; do
    ((++cluster_index))
    cluster_name_file="${SHARED_DIR}/managed-cluster-name-${cluster_index}"
    echo "${cluster_name}" > "${cluster_name_file}"
    echo "[INFO] Cluster ${cluster_index} name '${cluster_name}' written to ${cluster_name_file}"
done

# Also write all names to a single file (one per line) for batch processing
typeset all_cluster_names_file="${SHARED_DIR}/managed-cluster-names"
printf '%s\n' "${cluster_names[@]}" > "${all_cluster_names_file}"
echo "[INFO] All cluster names written to ${all_cluster_names_file}"

# Write cluster regions to a file (one per line) for use by other steps
typeset all_cluster_regions_file="${SHARED_DIR}/managed-cluster-regions"
printf '%s\n' "${cluster_regions[@]}" > "${all_cluster_regions_file}"
echo "[INFO] All cluster regions written to ${all_cluster_regions_file}"

# Maintain backward compatibility with single-cluster workflows
echo "${cluster_names[0]}" > "${SHARED_DIR}/managed-cluster-name"

#=====================
# Function: CreateClusterResources
#=====================
# Creates all Kubernetes resources needed to provision a spoke cluster.
# This includes namespace, secrets, and ACM/Hive resources.
#
# Arguments:
#   $1 - cluster_name:   Name of the cluster to create
#   $2 - cluster_idx:    Index number of the cluster (1-based)
#   $3 - cluster_region: AWS region for the cluster (from lease)
#
# Resources created:
#   - Namespace (same name as cluster)
#   - ManagedClusterSet (groups related clusters)
#   - ManagedClusterSetBinding (binds set to namespace)
#   - Secrets: AWS credentials, pull-secret, SSH keys, install-config
#   - ClusterDeployment (Hive resource that triggers installation)
#   - ManagedCluster (ACM resource for cluster management)
#   - KlusterletAddonConfig (enables ACM add-ons on spoke)
#
CreateClusterResources() {
    typeset cluster_name="$1"
    typeset cluster_idx="$2"
    typeset cluster_region="$3"

    echo "[INFO] =========================================="
    echo "[INFO] Creating resources for cluster ${cluster_idx}/${ACM_SPOKE_CLUSTER_COUNT}: ${cluster_name}"
    echo "[INFO] Region: ${cluster_region}"
    echo "[INFO] =========================================="

    # Create dedicated namespace for the cluster
    # All cluster-specific resources will be created in this namespace
    echo "[INFO] Creating namespace '${cluster_name}'"
    oc create namespace "${cluster_name}" --dry-run=client -o yaml | oc apply -f -

    # Create ManagedClusterSet to group this cluster
    # ManagedClusterSet is a cluster-scoped resource (no namespace)
    echo "[INFO] Creating ManagedClusterSet '${cluster_name}-set'"
    oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: ${cluster_name}-set
spec: {}
EOF

    # Bind the ManagedClusterSet to the cluster's namespace
    # This allows the namespace to use the cluster set
    echo "[INFO] Creating ManagedClusterSetBinding '${cluster_name}-set'"
    oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${cluster_name}-set
  namespace: ${cluster_name}
spec:
  clusterSet: ${cluster_name}-set
EOF

    # Create AWS credentials secret from cluster profile
    # Uses process substitution to avoid exposing credentials in logs
    # The 'set +x' disables command echoing for security
    echo "[INFO] Creating AWS credentials secret"
    oc -n "${cluster_name}" create secret generic acm-aws-secret \
        --type=Opaque \
        --from-file=aws_access_key_id=<(
            set +x
            printf '%s' "$(
                cat "${CLUSTER_PROFILE_DIR}/.awscred" |
                    sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q'
            )"
            true
        ) \
        --from-file=aws_secret_access_key=<(
            set +x
            printf '%s' "$(
                cat "${CLUSTER_PROFILE_DIR}/.awscred" |
                    sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q'
            )"
            true
        ) \
        --dry-run=client -o yaml | oc apply -f -

    # Label the secret for ACM credential discovery
    oc label secret acm-aws-secret \
        cluster.open-cluster-management.io/type=aws \
        cluster.open-cluster-management.io/credentials="" \
        -n "${cluster_name}" --overwrite \
        --dry-run=client -o yaml | oc apply -f -

    # Create pull-secret for accessing container registries
    echo "[INFO] Creating pull-secret"
    oc -n "${cluster_name}" create secret generic pull-secret \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson="${CLUSTER_PROFILE_DIR}/config.json" \
        --dry-run=client -o yaml | oc apply -f -

    # Create SSH key secrets for node access
    echo "[INFO] Creating SSH public key secret"
    oc -n "${cluster_name}" create secret generic ssh-public-key \
        --type=Opaque \
        --from-file=ssh-publickey="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
        --dry-run=client -o yaml | oc apply -f -

    echo "[INFO] Creating SSH private key secret"
    oc -n "${cluster_name}" create secret generic ssh-private-key \
        --type=Opaque \
        --from-file=ssh-privatekey="${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
        --dry-run=client -o yaml | oc apply -f -

    # Generate OpenShift install-config.yaml
    # This defines the cluster topology and infrastructure settings
    # Note: Uses the cluster-specific region from the lease
    echo "[INFO] Creating install-config for region '${cluster_region}'"
    typeset install_config_file="/tmp/install-config-${cluster_name}.yaml"

    cat > "${install_config_file}" <<EOF
apiVersion: v1
metadata:
  name: ${cluster_name}
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
    region: ${cluster_region}
sshKey: |-
  $(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
EOF

    # Store install-config as a secret for Hive to consume
    echo "[INFO] Creating install-config secret"
    oc -n "${cluster_name}" create secret generic install-config \
        --type Opaque \
        --from-file install-config.yaml="${install_config_file}" \
        --dry-run=client -o yaml --save-config | oc apply -f -

    # Create ClusterDeployment - this is the main Hive resource
    # that triggers the actual cluster installation
    # Note: Uses the cluster-specific region from the lease
    echo "[INFO] Creating ClusterDeployment '${cluster_name}' in region '${cluster_region}'"
    typeset cluster_deployment_file="/tmp/clusterdeployment-${cluster_name}.yaml"

    cat > "${cluster_deployment_file}" <<EOF
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: ${cluster_name}
  namespace: ${cluster_name}
  labels:
    cloud: 'AWS'
    region: '${cluster_region}'
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: '${cluster_name}-set'
spec:
  baseDomain: ${BASE_DOMAIN}
  clusterName: ${cluster_name}
  controlPlaneConfig:
    servingCertificates: {}
  platform:
    aws:
      region: ${cluster_region}
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

    # Create ManagedCluster - registers the cluster with ACM hub
    # hubAcceptsClient: true auto-approves the cluster registration
    echo "[INFO] Creating ManagedCluster '${cluster_name}'"
    typeset managed_cluster_file="/tmp/managed_cluster-${cluster_name}.yaml"

    cat > "${managed_cluster_file}" <<EOF
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${cluster_name}
  labels:
    name: ${cluster_name}
    cloud: Amazon
    region: ${cluster_region}
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: ${cluster_name}-set
spec:
  hubAcceptsClient: true
EOF

    oc apply -f "${managed_cluster_file}"

    # Create KlusterletAddonConfig - enables ACM features on the spoke cluster
    # This configures which ACM add-ons are deployed to the spoke
    echo "[INFO] Creating KlusterletAddonConfig '${cluster_name}'"
    typeset klusterlet_addon_config_file="/tmp/klusterletaddonconfig-${cluster_name}.yaml"

    cat > "${klusterlet_addon_config_file}" <<EOF
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: ${cluster_name}
  namespace: ${cluster_name}
spec:
  clusterName: ${cluster_name}
  clusterNamespace: ${cluster_name}
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

    echo "[INFO] Resources created for cluster ${cluster_name} in region ${cluster_region}"
    true
}

#=====================
# Function: WaitForClusterProvisioned
#=====================
# Waits for a ClusterDeployment to reach Provisioned=True status.
# This indicates the cluster installation has completed successfully.
#
# Arguments:
#   $1 - cluster_name: Name of the cluster to wait for
#   $2 - cluster_idx:  Index number of the cluster (1-based)
#
# Exits with error code 3 if provisioning fails or times out.
#
WaitForClusterProvisioned() {
    typeset cluster_name="$1"
    typeset cluster_idx="$2"

    # Wait for the Provisioned condition using oc wait
    echo "[INFO] Waiting for ClusterDeployment '${cluster_name}' to reach Provisioned=True (timeout=${ACM_SPOKE_INSTALL_TIMEOUT_MINUTES}m)"
    oc -n "${cluster_name}" wait "ClusterDeployment/${cluster_name}" \
        --for condition=Provisioned \
        --timeout "${ACM_SPOKE_INSTALL_TIMEOUT_MINUTES}m"

    # Verify the final status by checking conditions directly
    echo "[INFO] Verifying cluster ${cluster_idx} provisioning status"
    typeset cd_json
    cd_json="$(JsonGet "${cluster_name}" clusterdeployment "${cluster_name}")"

    # Extract the Provisioned condition status
    typeset provisioned
    provisioned="$(echo "${cd_json}" | jq -r '
        .status.conditions[]?
        | select(.type=="Provisioned" and .status=="True")
        | .type
    ')"

    if [[ "${provisioned}" == "Provisioned" ]]; then
        echo "[SUCCESS] Cluster ${cluster_idx} (${cluster_name}) - ClusterDeployment status Provisioned is True"
    else
        # If not provisioned, check for ProvisionStopped condition for error details
        typeset stop_reason
        stop_reason="$(echo "${cd_json}" | jq -r '
            .status.conditions[]?
            | select(.type=="ProvisionStopped" and .status=="True")
            | .reason // "N/A"
        ')"
        echo "[FATAL] Cluster ${cluster_idx} (${cluster_name}) - Installation failed. ProvisionStopped reason: ${stop_reason}" >&2
        exit 3
    fi
    true
}

#=====================
# Function: ExtractClusterCredentials
#=====================
# Extracts the admin kubeconfig and metadata from a provisioned cluster.
# These are stored in secrets created by Hive after successful provisioning.
#
# Arguments:
#   $1 - cluster_name: Name of the cluster
#   $2 - cluster_idx:  Index number of the cluster (1-based)
#
# Output files:
#   - ${SHARED_DIR}/managed-cluster-kubeconfig-{N}    : Admin kubeconfig
#   - ${SHARED_DIR}/managed-cluster-metadata-{N}.json : Cluster metadata
#
ExtractClusterCredentials() {
    typeset cluster_name="$1"
    typeset cluster_idx="$2"

    # Get the admin kubeconfig from the secret referenced in ClusterDeployment
    echo "[INFO] Extracting admin kubeconfig for cluster ${cluster_idx}: ${cluster_name}"
    typeset admin_kubeconfig_secret_name
    admin_kubeconfig_secret_name="$(
        oc -n "${cluster_name}" get "ClusterDeployment/${cluster_name}" \
            -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}'
    )"

    if [[ -z "${admin_kubeconfig_secret_name}" ]]; then
        echo "[ERROR] Failed to get admin kubeconfig secret name for ${cluster_name}" >&2
        exit 1
    fi

    # Decode and save the kubeconfig
    typeset kubeconfig_file="${SHARED_DIR}/managed-cluster-kubeconfig-${cluster_idx}"
    oc -n "${cluster_name}" get "Secret/${admin_kubeconfig_secret_name}" \
        -o jsonpath='{.data.kubeconfig}' |
        base64 -d > "${kubeconfig_file}"

    echo "[INFO] Kubeconfig for cluster ${cluster_idx} saved to ${kubeconfig_file}"

    # Extract cluster metadata (contains infraID, clusterID, etc.)
    typeset metadata_secret
    metadata_secret="$(
        oc -n "${cluster_name}" get "ClusterDeployment/${cluster_name}" \
            -o jsonpath='{.spec.clusterMetadata.metadataJSONSecretRef.name}'
    )"

    if [[ -z "${metadata_secret}" ]]; then
        echo "[WARN] metadataJSONSecretRef is not set for ${cluster_name}; metadata.json may not exist"
    else
        if oc -n "${cluster_name}" get secret "${metadata_secret}" >/dev/null 2>&1; then
            typeset metadata_file="${SHARED_DIR}/managed-cluster-metadata-${cluster_idx}.json"
            oc -n "${cluster_name}" get secret "${metadata_secret}" \
                -o jsonpath='{.data.metadata\.json}' | base64 -d \
                > "${metadata_file}"
            echo "[INFO] Cluster ${cluster_idx} metadata extracted to ${metadata_file}"
        else
            echo "[ERROR] Secret '${metadata_secret}' not found in namespace '${cluster_name}'" >&2
        fi
    fi
    true
}

#=====================
# Main execution: Create all clusters
#=====================
# The installation process has three phases:
# 1. Create resources - Sets up all K8s resources for each cluster
# 2. Wait for provisioning - Monitors ClusterDeployment status
# 3. Extract credentials - Retrieves kubeconfig and metadata

echo "[INFO] =========================================="
echo "[INFO] Starting creation of ${ACM_SPOKE_CLUSTER_COUNT} spoke cluster(s)"
echo "[INFO] Regions: ${cluster_regions[*]}"
echo "[INFO] =========================================="

# Declare loop index variable once for all phases
typeset idx=0

# Phase 1: Create all cluster resources
# This initiates the provisioning process for all clusters in parallel
# Each cluster is deployed to its corresponding region from the lease
for ((i = 0; i < ${#cluster_names[@]}; i++)); do
    idx=$((i + 1))
    CreateClusterResources "${cluster_names[i]}" "${idx}" "${cluster_regions[i]}"
done

echo "[INFO] All cluster resources created. Waiting for provisioning..."

# Phase 2: Wait for all clusters to complete provisioning
# Each cluster typically takes 30-45 minutes to provision
for ((i = 0; i < ${#cluster_names[@]}; i++)); do
    idx=$((i + 1))
    WaitForClusterProvisioned "${cluster_names[i]}" "${idx}"
done

echo "[INFO] All clusters provisioned. Extracting credentials..."

# Phase 3: Extract credentials for all provisioned clusters
for ((i = 0; i < ${#cluster_names[@]}; i++)); do
    idx=$((i + 1))
    ExtractClusterCredentials "${cluster_names[i]}" "${idx}"
done

# Create symlinks for backward compatibility with single-cluster workflows
# This allows existing steps that expect 'managed-cluster-kubeconfig' to work
ln -sf "managed-cluster-kubeconfig-1" "${SHARED_DIR}/managed-cluster-kubeconfig"
ln -sf "managed-cluster-metadata-1.json" "${SHARED_DIR}/managed.cluster.metadata.json"

# Print summary of created resources
echo "[INFO] =========================================="
echo "[SUCCESS] All ${ACM_SPOKE_CLUSTER_COUNT} spoke cluster(s) provisioned and registered with ACM"
echo "[INFO] =========================================="
for ((i = 0; i < ${#cluster_names[@]}; i++)); do
    idx=$((i + 1))
    echo "[INFO] Cluster ${idx}: ${cluster_names[i]} (Region: ${cluster_regions[i]})"
done
echo "[INFO] =========================================="
echo "[INFO] Cluster names file: ${SHARED_DIR}/managed-cluster-names"
echo "[INFO] Cluster regions file: ${SHARED_DIR}/managed-cluster-regions"
echo "[INFO] Individual cluster name files: ${SHARED_DIR}/managed-cluster-name-{1..${ACM_SPOKE_CLUSTER_COUNT}}"
echo "[INFO] Kubeconfig files: ${SHARED_DIR}/managed-cluster-kubeconfig-{1..${ACM_SPOKE_CLUSTER_COUNT}}"
