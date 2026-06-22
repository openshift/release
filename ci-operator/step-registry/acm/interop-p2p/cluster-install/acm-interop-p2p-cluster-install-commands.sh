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
# Output Files (per cluster, written to SHARED_DIR):
#   - managed-cluster-name-{N}         : Cluster name
#   - managed-cluster-kubeconfig-{N}   : Admin kubeconfig (for oc --kubeconfig)
#   - managed-cluster-password-{N}     : kubeadmin password (plain text)
#   - managed-cluster-metadata-{N}.json: Cluster metadata (infraID, clusterID)
#
# Backward-compat symlinks (→ cluster 1, for single-cluster consumers):
#   - managed-cluster-name             : First cluster name (written directly)
#   - managed-cluster-kubeconfig       : Symlink → managed-cluster-kubeconfig-1
#   - managed-cluster-password         : Symlink → managed-cluster-password-1
#   - managed-cluster-metadata.json    : Symlink → managed-cluster-metadata-1.json
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
typeset -a clusterRegionsArr=()
if [[ -n "${MANAGED_CLUSTER_LEASED_RESOURCE:-}" ]]; then
    read -ra clusterRegionsArr <<< "${MANAGED_CLUSTER_LEASED_RESOURCE}"
else
    echo "[ERROR] MANAGED_CLUSTER_LEASED_RESOURCE is not set or empty" >&2
    exit 1
fi

: "Parsed ${#clusterRegionsArr[@]} region(s) from leases"

#=====================
# Validate required files
#=====================
[ -f "${SHARED_DIR}/metadata.json" ] || {
    echo "[ERROR] Required file not found: ${SHARED_DIR}/metadata.json" >&2
    exit 1
}

#=====================
# Validate cluster count
#=====================
if [[ ! "${ACM_SPOKE_CLUSTER_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERROR] ACM_SPOKE_CLUSTER_COUNT must be a positive integer, got: '${ACM_SPOKE_CLUSTER_COUNT}'" >&2
    exit 1
fi

if [[ "${ACM_SPOKE_CLUSTER_COUNT}" -gt 3 ]]; then
    echo "[ERROR] ACM_SPOKE_CLUSTER_COUNT exceeds maximum of 3, got: '${ACM_SPOKE_CLUSTER_COUNT}'" >&2
    exit 1
fi

#=====================
# Validate lease count matches cluster count
#=====================
if [[ "${#clusterRegionsArr[@]}" -ne "${ACM_SPOKE_CLUSTER_COUNT}" ]]; then
    echo "[ERROR] Lease count mismatch: got ${#clusterRegionsArr[@]} lease(s) but ACM_SPOKE_CLUSTER_COUNT=${ACM_SPOKE_CLUSTER_COUNT}" >&2
    echo "[ERROR] Each cluster requires exactly one lease. Ensure 'count' in leases configuration matches ACM_SPOKE_CLUSTER_COUNT" >&2
    exit 1
fi

#=====================
# Helper functions
#=====================

# Need - Verify that a required command is available
Need() {
    command -v "$1" 1>/dev/null || {
        echo "[FATAL] '$1' not found" >&2
        exit 1
    }
    true
}

#=====================
# InstallYq — install yq to /tmp/bin if not already in PATH
#=====================
# yq converts JSON output from jq back to YAML for Kubernetes manifests.
# The cli-jq image ships oc and jq but not yq; this function downloads
# a pinned release on demand and prepends /tmp/bin to PATH.
InstallYq() {
    if command -v yq 1>/dev/null; then
        : "yq already in PATH"
        return
    fi
    typeset -r yqVersion="v4.44.2"
    typeset yqArch
    yqArch="$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')"
    : "Installing yq ${yqVersion} (${yqArch}) to /tmp/bin"
    mkdir -p /tmp/bin
    curl -fsSL \
        "https://github.com/mikefarah/yq/releases/download/${yqVersion}/yq_linux_${yqArch}" \
        -o /tmp/bin/yq
    chmod +x /tmp/bin/yq
    export PATH="/tmp/bin:${PATH}"
    true
}

Need oc
Need jq
Need curl
Need base64
InstallYq

#=====================
# Get hub cluster name for suffix generation
#=====================
typeset hubClusterName
hubClusterName="$(jq -r '.clusterName' "${SHARED_DIR}/metadata.json")"
if [[ -z "${hubClusterName}" ]]; then
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
# ClusterImageSets are named like: img4.14.0-x86_64, img4.14.1-x86_64, etc.
if [[ -z "${ACM_SPOKE_CLUSTER_INITIAL_VERSION}" ]]; then
    echo "[ERROR] ACM_SPOKE_CLUSTER_INITIAL_VERSION must be set (e.g. 4.20)" >&2
    exit 1
fi
typeset clusterImagesetName
# grep exits 1 when there is no match; with pipefail that would abort before the empty check below
clusterImagesetName="$(
    oc get clusterimagesets.hive.openshift.io \
        -o jsonpath='{.items[*].metadata.name}' |
        tr ' ' '\n' |
        grep "^img${ACM_SPOKE_CLUSTER_INITIAL_VERSION}\." |
        sort -V |
        tail -n 1
)" || true

if [[ -z "${clusterImagesetName}" ]]; then
    echo "[ERROR] No cluster image set found for version '${ACM_SPOKE_CLUSTER_INITIAL_VERSION}'" >&2
    exit 1
fi

if ! oc get clusterimageset "${clusterImagesetName}" 1>/dev/null; then
    echo "[ERROR] ClusterImageSet '${clusterImagesetName}' not found or not accessible" >&2
    exit 1
fi

typeset ocpReleaseImage
ocpReleaseImage="$(
    oc get clusterimageset "${clusterImagesetName}" \
        -o jsonpath='{.spec.releaseImage}' || echo ""
)"

#=====================
# Generate unique cluster names
#=====================
# Create a base suffix from the hub cluster name hash (first 5 chars)
typeset baseSuffix
baseSuffix="$(echo -n "${hubClusterName}" | sha1sum | cut -c1-5)"
if [[ -z "${baseSuffix}" ]]; then
    echo "[ERROR] Failed to generate cluster name base suffix" >&2
    exit 1
fi

# Build array of cluster names: {prefix}-{hash}-{index}
# Example: acm-spoke-a1b2c-1, acm-spoke-a1b2c-2, acm-spoke-a1b2c-3
typeset -a clusterNamesArr=()
typeset uniqueSuffix=""
typeset clusterName=""
for ((i = 1; i <= ACM_SPOKE_CLUSTER_COUNT; i++)); do
    uniqueSuffix="${baseSuffix}-${i}"
    clusterName="${ACM_SPOKE_CLUSTER_NAME_PREFIX}-${uniqueSuffix}"
    clusterNamesArr+=("${clusterName}")
done

#=====================
# Write cluster names to individual files
#=====================
typeset clusterIndex=0
typeset clusterNameFile=""
for clusterName in "${clusterNamesArr[@]}"; do
    ((++clusterIndex))
    clusterNameFile="${SHARED_DIR}/managed-cluster-name-${clusterIndex}"
    echo "${clusterName}" > "${clusterNameFile}"
done

# All names in a single file (one per line) for batch processing
typeset allClusterNamesFile="${SHARED_DIR}/managed-cluster-names"
printf '%s\n' "${clusterNamesArr[@]}" > "${allClusterNamesFile}"

# All regions in a single file (one per line) for use by other steps
typeset allClusterRegionsFile="${SHARED_DIR}/managed-cluster-regions"
printf '%s\n' "${clusterRegionsArr[@]}" > "${allClusterRegionsFile}"

# Maintain backward compatibility with single-cluster workflows
echo "${clusterNamesArr[0]}" > "${SHARED_DIR}/managed-cluster-name"

#=====================
# Function: CreateClusterResources
#=====================
# Creates all Kubernetes resources needed to provision a spoke cluster.
# This includes namespace, secrets, and ACM/Hive resources.
#
# Arguments:
#   $1 - clusterName:   Name of the cluster to create
#   $2 - clusterIdx:    Index number of the cluster (1-based)
#   $3 - clusterRegion: AWS region for the cluster (from lease)
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
    typeset clusterName="$1"
    typeset clusterIdx="$2"
    typeset clusterRegion="$3"

    : "Creating resources for cluster ${clusterIdx}/${ACM_SPOKE_CLUSTER_COUNT}: ${clusterName} (region=${clusterRegion})"

    oc create namespace "${clusterName}" --dry-run=client -o yaml | oc apply -f -

    # ManagedClusterSet is cluster-scoped (no namespace)
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c --arg name "${clusterName}-set" '
            .metadata.name = $name
        '
    } 0<<'ocEOF' | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: placeholder
spec: {}
ocEOF

    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --arg name "${clusterName}-set" \
            --arg ns   "${clusterName}" \
            '
            .metadata.name      = $name |
            .metadata.namespace = $ns   |
            .spec.clusterSet    = $name
            '
    } 0<<'ocEOF' | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: placeholder
  namespace: placeholder
spec:
  clusterSet: placeholder
ocEOF

    # AWS credentials via process substitution; set+x prevents xtrace exposing secrets
    oc -n "${clusterName}" create secret generic acm-aws-secret \
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

    oc label secret acm-aws-secret \
        cluster.open-cluster-management.io/type=aws \
        cluster.open-cluster-management.io/credentials="" \
        -n "${clusterName}" --overwrite \
        --dry-run=client -o yaml | oc apply -f -

    oc -n "${clusterName}" create secret generic pull-secret \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson="${CLUSTER_PROFILE_DIR}/config.json" \
        --dry-run=client -o yaml | oc apply -f -

    oc -n "${clusterName}" create secret generic ssh-public-key \
        --type=Opaque \
        --from-file=ssh-publickey="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
        --dry-run=client -o yaml | oc apply -f -

    oc -n "${clusterName}" create secret generic ssh-private-key \
        --type=Opaque \
        --from-file=ssh-privatekey="${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
        --dry-run=client -o yaml | oc apply -f -

    # install-config is NOT a Kubernetes resource; oc create --dry-run would fail
    # with "Kind is missing". Build JSON directly via jq; JSON is valid YAML superset.
    typeset installConfigFile="/tmp/install-config-${clusterName}.yaml"
    jq -cn \
        --arg name     "${clusterName}" \
        --arg domain   "${BASE_DOMAIN}" \
        --arg arch     "${ACM_SPOKE_ARCH_TYPE}" \
        --arg cpType   "${ACM_SPOKE_CP_TYPE}" \
        --argjson cpR  "${ACM_SPOKE_CP_REPLICAS}" \
        --arg wkType   "${ACM_SPOKE_WORKER_TYPE}" \
        --argjson wkR  "${ACM_SPOKE_WORKER_REPLICAS}" \
        --arg netType  "${ACM_SPOKE_NETWORK_TYPE}" \
        --arg region   "${clusterRegion}" \
        --arg sshKey   "$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")" \
        '{
            "apiVersion": "v1",
            "metadata": {"name": $name},
            "baseDomain": $domain,
            "controlPlane": {
                "architecture": $arch,
                "hyperthreading": "Enabled",
                "name": "master",
                "replicas": $cpR,
                "platform": {"aws": {"type": $cpType}}
            },
            "compute": [
                {
                    "hyperthreading": "Enabled",
                    "architecture": $arch,
                    "name": "worker",
                    "replicas": $wkR,
                    "platform": {"aws": {"type": $wkType}}
                }
            ],
            "networking": {
                "networkType": $netType,
                "clusterNetwork": [{"cidr": "10.128.0.0/14", "hostPrefix": 23}],
                "machineNetwork": [{"cidr": "10.0.0.0/16"}],
                "serviceNetwork": ["172.30.0.0/16"]
            },
            "platform": {"aws": {"region": $region}},
            "sshKey": $sshKey
        }' > "${installConfigFile}"

    oc -n "${clusterName}" create secret generic install-config \
        --type Opaque \
        --from-file install-config.yaml="${installConfigFile}" \
        --dry-run=client -o yaml --save-config | oc apply -f -

    # ClusterDeployment — main Hive resource that triggers cluster installation
    typeset clusterDeploymentFile="/tmp/clusterdeployment-${clusterName}.yaml"
    {
        oc create -f - --dry-run=client -o json |
        jq -c \
            --arg name       "${clusterName}" \
            --arg region     "${clusterRegion}" \
            --arg domain     "${BASE_DOMAIN}" \
            --arg clusterSet "${clusterName}-set" \
            --arg imageSet   "${clusterImagesetName}" \
            '
            .metadata.name                                         = $name      |
            .metadata.namespace                                    = $name      |
            .metadata.labels.region                                = $region    |
            .metadata.labels["cluster.open-cluster-management.io/clusterset"] = $clusterSet |
            .spec.baseDomain                                       = $domain    |
            .spec.clusterName                                      = $name      |
            .spec.platform.aws.region                              = $region    |
            .spec.provisioning.imageSetRef.name                    = $imageSet
            ' |
        yq -p json -o yaml eval .
    } 0<<'ocEOF' > "${clusterDeploymentFile}"
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: placeholder
  namespace: placeholder
  labels:
    cloud: 'AWS'
    region: placeholder
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: placeholder
spec:
  baseDomain: placeholder
  clusterName: placeholder
  controlPlaneConfig:
    servingCertificates: {}
  platform:
    aws:
      region: placeholder
      credentialsSecretRef:
        name: acm-aws-secret
  pullSecretRef:
    name: pull-secret
  installAttemptsLimit: 1
  provisioning:
    installConfigSecretRef:
      name: install-config
    imageSetRef:
      name: placeholder
    sshPrivateKeyRef:
      name: ssh-private-key
ocEOF

    oc apply -f "${clusterDeploymentFile}"

    # ManagedCluster — registers the cluster with ACM hub
    typeset managedClusterFile="/tmp/managed_cluster-${clusterName}.yaml"
    {
        oc create -f - --dry-run=client -o json |
        jq -c \
            --arg name       "${clusterName}" \
            --arg region     "${clusterRegion}" \
            --arg clusterSet "${clusterName}-set" \
            '
            .metadata.name                                         = $name      |
            .metadata.labels.name                                  = $name      |
            .metadata.labels.region                                = $region    |
            .metadata.labels["cluster.open-cluster-management.io/clusterset"] = $clusterSet
            ' |
        yq -p json -o yaml eval .
    } 0<<'ocEOF' > "${managedClusterFile}"
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: placeholder
  labels:
    name: placeholder
    cloud: Amazon
    region: placeholder
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: placeholder
spec:
  hubAcceptsClient: true
ocEOF

    oc apply -f "${managedClusterFile}"

    # KlusterletAddonConfig — enables ACM add-ons on the spoke
    typeset klusterletAddonConfigFile="/tmp/klusterletaddonconfig-${clusterName}.yaml"
    {
        oc create -f - --dry-run=client -o json |
        jq -c \
            --arg name "${clusterName}" \
            '
            .metadata.name      = $name |
            .metadata.namespace = $name |
            .spec.clusterName      = $name |
            .spec.clusterNamespace = $name
            ' |
        yq -p json -o yaml eval .
    } 0<<'ocEOF' > "${klusterletAddonConfigFile}"
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: placeholder
  namespace: placeholder
spec:
  clusterName: placeholder
  clusterNamespace: placeholder
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
ocEOF

    oc apply -f "${klusterletAddonConfigFile}"
    true
}

#=====================
# Function: WaitForClusterProvisioned
#=====================
# Waits for a ClusterDeployment to reach Provisioned=True status.
#
# Arguments:
#   $1 - clusterName: Name of the cluster to wait for
#   $2 - clusterIdx:  Index number of the cluster (1-based)
#
# Exits with error code 3 if provisioning fails or times out.
#
WaitForClusterProvisioned() {
    typeset clusterName="$1"
    typeset clusterIdx="$2"

    typeset -i pollInterval=30
    typeset -i timeoutSeconds=$(( ACM_SPOKE_INSTALL_TIMEOUT_MINUTES * 60 ))
    typeset -i deadline=$(( $(date +%s) + timeoutSeconds ))

    : "Polling ClusterDeployment '${clusterName}' for Provisioned=True (timeout=${ACM_SPOKE_INSTALL_TIMEOUT_MINUTES}m)"

    typeset cdJson stopReason stopMessage provisioned elapsed

    while true; do
        cdJson="$(oc -n "${clusterName}" get "clusterdeployment/${clusterName}" -o json)" || {
            echo "[WARN] Failed to fetch ClusterDeployment '${clusterName}', will retry..." >&2
            sleep "${pollInterval}"
            continue
        }

        # ProvisionStopped=True means Hive has permanently given up — fail fast
        stopReason="$(echo "${cdJson}" | jq -r '
            .status.conditions[]?
            | select(.type=="ProvisionStopped" and .status=="True")
            | .reason // "N/A"
        ')"
        if [[ -n "${stopReason}" ]]; then
            stopMessage="$(echo "${cdJson}" | jq -r '
                .status.conditions[]?
                | select(.type=="ProvisionStopped" and .status=="True")
                | .message // "N/A"
            ')"
            echo "[FATAL] Cluster ${clusterIdx} (${clusterName}) - ProvisionStopped=True" >&2
            echo "[FATAL] Reason:  ${stopReason}" >&2
            echo "[FATAL] Message: ${stopMessage}" >&2
            exit 3
        fi

        provisioned="$(echo "${cdJson}" | jq -r '
            .status.conditions[]?
            | select(.type=="Provisioned" and .status=="True")
            | .type
        ')"
        if [[ "${provisioned}" == "Provisioned" ]]; then
            echo "[SUCCESS] Cluster ${clusterIdx} (${clusterName}) - ClusterDeployment Provisioned=True"
            true
            return
        fi

        if (( $(date +%s) >= deadline )); then
            elapsed=$(( $(date +%s) - (deadline - timeoutSeconds) ))
            echo "[FATAL] Cluster ${clusterIdx} (${clusterName}) - Timed out after ${elapsed}s" \
                 "waiting for Provisioned=True (limit=${ACM_SPOKE_INSTALL_TIMEOUT_MINUTES}m)" >&2
            echo "${cdJson}" | jq -r '.status.conditions[]? | "  \(.type)=\(.status) reason=\(.reason // "N/A")"' >&2
            exit 3
        fi

        elapsed=$(( $(date +%s) - (deadline - timeoutSeconds) ))
        : "Cluster ${clusterIdx} (${clusterName}) - still provisioning (${elapsed}s elapsed)"
        sleep "${pollInterval}"
    done
}

#=====================
# Function: ExtractClusterCredentials
#=====================
# Extracts the admin kubeconfig, kubeadmin password, and metadata from a
# provisioned cluster (from Hive-created secrets).
#
# Arguments:
#   $1 - clusterName: Name of the cluster
#   $2 - clusterIdx:  Index number of the cluster (1-based)
#
# Output files written to SHARED_DIR:
#   - managed-cluster-kubeconfig-{N}    : Admin kubeconfig
#   - managed-cluster-password-{N}      : kubeadmin password (plain text)
#   - managed-cluster-metadata-{N}.json : Cluster metadata (infraID, clusterID, etc.)
#
ExtractClusterCredentials() {
    typeset clusterName="$1"
    typeset clusterIdx="$2"

    # Fetch ClusterDeployment once; all secret refs are inside it
    typeset cdJson
    cdJson="$(oc -n "${clusterName}" get "ClusterDeployment/${clusterName}" -o json)"

    #------------------------------------------------------------------
    # Admin kubeconfig
    #------------------------------------------------------------------
    typeset adminKubeconfigSecretName
    adminKubeconfigSecretName="$(echo "${cdJson}" | jq -r '.spec.clusterMetadata.adminKubeconfigSecretRef.name // empty')"

    if [[ -z "${adminKubeconfigSecretName}" ]]; then
        echo "[ERROR] adminKubeconfigSecretRef not set in ClusterDeployment for ${clusterName}" >&2
        exit 1
    fi

    typeset kubeconfigFile="${SHARED_DIR}/managed-cluster-kubeconfig-${clusterIdx}"
    oc -n "${clusterName}" get "Secret/${adminKubeconfigSecretName}" \
        -o jsonpath='{.data.kubeconfig}' | base64 -d > "${kubeconfigFile}"
    echo "[SUCCESS] Kubeconfig for cluster ${clusterIdx} (${clusterName}) saved"

    #------------------------------------------------------------------
    # Admin password — Hive stores kubeadmin credentials in adminPasswordSecretRef
    #------------------------------------------------------------------
    typeset adminPasswordSecretName
    adminPasswordSecretName="$(echo "${cdJson}" | jq -r '.spec.clusterMetadata.adminPasswordSecretRef.name // empty')"

    if [[ -n "${adminPasswordSecretName}" ]]; then
        typeset passwordFile="${SHARED_DIR}/managed-cluster-password-${clusterIdx}"
        oc -n "${clusterName}" get "Secret/${adminPasswordSecretName}" \
            -o jsonpath='{.data.password}' | base64 -d > "${passwordFile}"
        echo "[SUCCESS] Admin password for cluster ${clusterIdx} (${clusterName}) saved"
    else
        echo "[WARN] adminPasswordSecretRef not set for ${clusterName}; managed-cluster-password-${clusterIdx} will not be written" >&2
    fi

    #------------------------------------------------------------------
    # Cluster metadata (infraID, clusterID, etc.)
    #------------------------------------------------------------------
    typeset metadataSecret
    metadataSecret="$(echo "${cdJson}" | jq -r '.spec.clusterMetadata.metadataJSONSecretRef.name // empty')"

    if [[ -z "${metadataSecret}" ]]; then
        echo "[WARN] metadataJSONSecretRef is not set for ${clusterName}; metadata.json will not be written" >&2
    else
        if oc -n "${clusterName}" get secret "${metadataSecret}" 1>/dev/null; then
            typeset metadataFile="${SHARED_DIR}/managed-cluster-metadata-${clusterIdx}.json"
            oc -n "${clusterName}" get secret "${metadataSecret}" \
                -o jsonpath='{.data.metadata\.json}' | base64 -d > "${metadataFile}"
            echo "[SUCCESS] Cluster ${clusterIdx} metadata extracted"
        else
            echo "[ERROR] Secret '${metadataSecret}' not found in namespace '${clusterName}';" \
                 "managed-cluster-metadata-${clusterIdx}.json will not be written" >&2
            exit 1
        fi
    fi
    true
}

#=====================
# Function: WaitForManagedClusterAvailable
#=====================
# Waits for a ManagedCluster to reach Available=True status.
# This confirms the spoke's klusterlet has connected to the hub ACM,
# which is required for the acm-fetch-managed-clusters step to discover
# the cluster and retrieve its credentials.
#
# Arguments:
#   $1 - clusterName: Name of the managed cluster
#   $2 - clusterIdx:  Index number of the cluster (1-based)
#
WaitForManagedClusterAvailable() {
    typeset clusterName="$1"
    typeset clusterIdx="$2"
    typeset -i pollInterval=30
    # Allow up to 15 minutes for klusterlet to connect after provisioning completes
    typeset -i timeoutSeconds=900
    typeset -i deadline=$(( $(date +%s) + timeoutSeconds ))

    : "Waiting for ManagedCluster ${clusterIdx} (${clusterName}) to be Available"

    typeset mcAvail=""
    while true; do
        mcAvail="$(
            oc get managedcluster "${clusterName}" \
                -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' || echo ""
        )"

        if [[ "${mcAvail}" == "True" ]]; then
            echo "[SUCCESS] ManagedCluster ${clusterIdx} (${clusterName}) is Available"
            true
            return
        fi

        if (( $(date +%s) >= deadline )); then
            echo "[WARN] ManagedCluster ${clusterIdx} (${clusterName}) not Available after ${timeoutSeconds}s" \
                 "(status='${mcAvail:-Unknown}'); proceeding — fetch step may not find this cluster" >&2
            true
            return
        fi

        : "ManagedCluster ${clusterIdx} (${clusterName}) not yet Available (status='${mcAvail:-Unknown}')"
        sleep "${pollInterval}"
    done
}

#=====================
# Main execution: Create all clusters
#=====================
# Phase 1: Create resources — Phase 2: Wait for provisioning — Phase 3: Extract credentials
# Phase 4: Wait for ManagedCluster Available (klusterlet connected to hub)

typeset idx=0

# Phase 1: Create all cluster resources (initiates provisioning in parallel)
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    idx=$((i + 1))
    CreateClusterResources "${clusterNamesArr[i]}" "${idx}" "${clusterRegionsArr[i]}"
done

echo "[INFO] All cluster resources created. Waiting for provisioning..."

# Phase 2: Wait for all clusters to complete provisioning (~30-45 min each)
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    idx=$((i + 1))
    WaitForClusterProvisioned "${clusterNamesArr[i]}" "${idx}"
done

echo "[INFO] All clusters provisioned. Extracting credentials..."

# Phase 3: Extract credentials for all provisioned clusters
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    idx=$((i + 1))
    ExtractClusterCredentials "${clusterNamesArr[i]}" "${idx}"
done

# Phase 4: Wait for ManagedClusters to join the hub (required for fetch step)
echo "[INFO] Waiting for all ManagedClusters to join the hub..."
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    idx=$((i + 1))
    WaitForManagedClusterAvailable "${clusterNamesArr[i]}" "${idx}"
done

# Backward-compatibility symlinks for single-cluster workflows.
# Steps that read 'managed-cluster-kubeconfig' (no index) resolve to cluster 1.
ln -sf "managed-cluster-kubeconfig-1" "${SHARED_DIR}/managed-cluster-kubeconfig"
ln -sf "managed-cluster-metadata-1.json" "${SHARED_DIR}/managed-cluster-metadata.json"
[ -f "${SHARED_DIR}/managed-cluster-password-1" ] && \
    ln -sf "managed-cluster-password-1" "${SHARED_DIR}/managed-cluster-password"

# Summary
echo "[SUCCESS] All ${ACM_SPOKE_CLUSTER_COUNT} spoke cluster(s) provisioned, credentials extracted, and registered with hub ACM"
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    idx=$((i + 1))
    echo "[INFO] Cluster ${idx}: ${clusterNamesArr[i]} (Region: ${clusterRegionsArr[i]})"
    echo "[INFO]   kubeconfig : ${SHARED_DIR}/managed-cluster-kubeconfig-${idx}"
    [ -f "${SHARED_DIR}/managed-cluster-password-${idx}" ] && \
        echo "[INFO]   password   : ${SHARED_DIR}/managed-cluster-password-${idx}"
done
echo "[INFO] Compat symlinks (→ cluster 1):"
echo "[INFO]   ${SHARED_DIR}/managed-cluster-name          → ${SHARED_DIR}/managed-cluster-name-1 content"
echo "[INFO]   ${SHARED_DIR}/managed-cluster-kubeconfig    → managed-cluster-kubeconfig-1"
echo "[INFO]   ${SHARED_DIR}/managed-cluster-metadata.json → managed-cluster-metadata-1.json"
[ -f "${SHARED_DIR}/managed-cluster-password" ] && \
    echo "[INFO]   ${SHARED_DIR}/managed-cluster-password       → managed-cluster-password-1"

true
