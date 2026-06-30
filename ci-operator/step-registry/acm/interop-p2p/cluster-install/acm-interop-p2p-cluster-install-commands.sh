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
# Networking:
#   Each spoke gets non-overlapping pod/VPC/service CIDRs derived from its
#   1-based index (hub defaults are 10.128.0.0/14, 10.0.0.0/16, 172.30.0.0/16).
#   Batch CIDR lists are written to managed-cluster-*-network-cidrs files.
#
# Prerequisites:
#   - Hub cluster with ACM installed
#   - Valid AWS credentials in cluster profile
#   - ClusterImageSet available for target OCP version
#   - Sufficient leases acquired for the number of clusters
#

set -euxo pipefail; shopt -s inherit_errexit
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

#=====================
# Parse leased resources into array
#=====================
# MANAGED_CLUSTER_LEASED_RESOURCE contains one AWS region per cluster lease
# Format: space-separated list of regions (e.g., "us-west-2 us-east-1 eu-west-1")
# Each cluster will be deployed to its corresponding region from this list
typeset -a clusterRegionsArr=()
if [[ -n "${MANAGED_CLUSTER_LEASED_RESOURCE:-}" ]]; then
    read -ra clusterRegionsArr <<< "${MANAGED_CLUSTER_LEASED_RESOURCE}"
else
    : "MANAGED_CLUSTER_LEASED_RESOURCE is not set or empty"
    exit 1
fi

: "Parsed ${#clusterRegionsArr[@]} region(s) from leases: ${clusterRegionsArr[*]}"

#=====================
# Validate required files
#=====================
# The metadata.json file contains hub cluster information needed
# to generate unique spoke cluster names
if [[ ! -f "${SHARED_DIR}/metadata.json" ]]; then
    : "Required file not found: ${SHARED_DIR}/metadata.json"
    exit 1
fi

#=====================
# Validate cluster count
#=====================
# Ensure cluster count is a valid positive integer
if [[ ! "${ACM_SPOKE_CLUSTER_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
    : "ACM_SPOKE_CLUSTER_COUNT must be a positive integer, got: '${ACM_SPOKE_CLUSTER_COUNT}'"
    exit 1
fi

# Limit maximum clusters to prevent resource exhaustion
if [[ "${ACM_SPOKE_CLUSTER_COUNT}" -gt 3 ]]; then
    : "ACM_SPOKE_CLUSTER_COUNT exceeds maximum of 3, got: '${ACM_SPOKE_CLUSTER_COUNT}'"
    exit 1
fi

#=====================
# Validate lease count matches cluster count
#=====================
# Each cluster requires exactly one lease (region)
# The number of leases must match the requested cluster count
if [[ "${#clusterRegionsArr[@]}" -ne "${ACM_SPOKE_CLUSTER_COUNT}" ]]; then
    : "Lease count mismatch: got ${#clusterRegionsArr[@]} lease(s) but ACM_SPOKE_CLUSTER_COUNT=${ACM_SPOKE_CLUSTER_COUNT}"
    : "Each cluster requires exactly one lease. Ensure 'count' in leases configuration matches ACM_SPOKE_CLUSTER_COUNT"
    exit 1
fi

: "Lease validation passed: ${ACM_SPOKE_CLUSTER_COUNT} cluster(s) with ${#clusterRegionsArr[@]} lease(s)"

#=====================
# Helper functions
#=====================

# Need - Verify that a required command is available
# Arguments:
#   $1 - Command name to check
# Exits with error if command is not found
Need() {
    command -v "$1" 1>/dev/null || {
        : "'$1' not found"
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

# ResolveSpokeCidrs — derive non-overlapping install-config CIDRs per spoke index.
# Hub IPI defaults (10.128.0.0/14, 10.0.0.0/16, 172.30.0.0/16) are skipped by
# offsetting each 1-based spoke index (max 3 spokes supported by this step).
# Arguments:
#   $1 - cluster_idx (1-based)
# Sets (caller-visible):
#   clusterNetworkCidr, machineNetworkCidr, serviceNetworkCidr
ResolveSpokeCidrs() {
    typeset -i clusterIdx="${1:?}"
    typeset -i clusterNetworkBaseOctet=$((128 + clusterIdx * 4))
    typeset -i serviceNetworkBaseOctet=$((30 + clusterIdx))

    clusterNetworkCidr="10.${clusterNetworkBaseOctet}.0.0/14"
    machineNetworkCidr="10.${clusterIdx}.0.0/16"
    serviceNetworkCidr="172.${serviceNetworkBaseOctet}.0.0/16"
    true
}

#=====================
# InstallYq — install yq to /tmp/bin if not already in PATH
#=====================
# The cli image ships oc but not yq; this function downloads a pinned
# release on demand and prepends /tmp/bin to PATH.
InstallYq() {
    if command -v yq 1>/dev/null; then
        : "yq already in PATH: $(yq --version 2>&1)"
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
    : "yq installed: $(yq --version 2>&1)"
    true
}

# Verify required CLI tools are available
Need oc
Need curl
Need base64
InstallYq

#=====================
# Get hub cluster name for suffix generation
#=====================
# Extract the hub cluster name from metadata.json
# This is used to generate unique spoke cluster names
typeset hubClusterName
hubClusterName="$(jq -r '.clusterName' "${SHARED_DIR}/metadata.json")"
if [[ -z "${hubClusterName}" ]]; then
    : "Could not extract hub cluster name from metadata.json"
    exit 1
fi

if [[ -z "${ACM_SPOKE_CLUSTER_NAME_PREFIX}" ]]; then
    : "ACM_SPOKE_CLUSTER_NAME_PREFIX is not set"
    exit 1
fi

#=====================
# Resolve cluster image set (once for all clusters)
#=====================
# Find the latest ClusterImageSet matching the target OCP version
# ClusterImageSets are named like: img4.14.0-x86_64, img4.14.1-x86_64, etc.
if [[ -z "${ACM_SPOKE_CLUSTER_INITIAL_VERSION}" ]]; then
    : "ACM_SPOKE_CLUSTER_INITIAL_VERSION must be set (e.g. 4.20)"
    exit 1
fi
: "Resolving cluster image set for version '${ACM_SPOKE_CLUSTER_INITIAL_VERSION}'"
typeset clusterImagesetName
# jq select avoids grep's non-zero exit on no match; sort -V preserves version ordering.
clusterImagesetName="$(
    oc get clusterimagesets.hive.openshift.io -o json |
    jq -r --arg prefix "img${ACM_SPOKE_CLUSTER_INITIAL_VERSION}." \
        '.items[].metadata.name | select(startswith($prefix))' |
    sort -V |
    tail -n 1
)"

if [[ -z "${clusterImagesetName}" ]]; then
    : "No cluster image set found for version '${ACM_SPOKE_CLUSTER_INITIAL_VERSION}'"
    exit 1
fi

# Double-check that the ClusterImageSet resource exists
if ! oc get clusterimageset "${clusterImagesetName}" 1>/dev/null; then
    : "ClusterImageSet '${clusterImagesetName}' not found or not accessible"
    exit 1
fi

: "Using cluster image set: ${clusterImagesetName}"

# Log the release image URL for debugging purposes
typeset ocpReleaseImage
ocpReleaseImage="$(
    oc get clusterimageset "${clusterImagesetName}" \
        -o jsonpath='{.spec.releaseImage}' || true
)"

if [[ -n "${ocpReleaseImage}" ]]; then
    : "Cluster image set release image: ${ocpReleaseImage}"
fi

#=====================
# Generate unique cluster names
#=====================
# Create a base suffix from the hub cluster name hash (first 5 chars)
# This ensures spoke cluster names are unique per hub cluster
typeset baseSuffix
baseSuffix="$(printf '%s' "${hubClusterName}" | sha1sum | cut -c1-5)"
if [[ -z "${baseSuffix}" ]]; then
    : "Failed to generate cluster name base suffix"
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

: "Will create ${#clusterNamesArr[@]} cluster(s):"
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    ResolveSpokeCidrs "$((i + 1))"
    : "  Cluster $((i+1)): ${clusterNamesArr[i]} -> Region: ${clusterRegionsArr[i]} pod=${clusterNetworkCidr} vpc=${machineNetworkCidr} svc=${serviceNetworkCidr}"
done

#=====================
# Write cluster names to individual files
#=====================
# Each cluster gets its own name file for use by subsequent steps
typeset -i clusterIndex=0
typeset clusterNameFile=""
for clusterName in "${clusterNamesArr[@]}"; do
    (( ++clusterIndex ))
    clusterNameFile="${SHARED_DIR}/managed-cluster-name-${clusterIndex}"
    printf '%s\n' "${clusterName}" > "${clusterNameFile}"
    : "Cluster ${clusterIndex} name '${clusterName}' written to ${clusterNameFile}"
done

# Also write all names to a single file (one per line) for batch processing
typeset allClusterNamesFile="${SHARED_DIR}/managed-cluster-names"
printf '%s\n' "${clusterNamesArr[@]}" > "${allClusterNamesFile}"
: "All cluster names written to ${allClusterNamesFile}"

# Write cluster regions to a file (one per line) for use by other steps
typeset allClusterRegionsFile="${SHARED_DIR}/managed-cluster-regions"
printf '%s\n' "${clusterRegionsArr[@]}" > "${allClusterRegionsFile}"
: "All cluster regions written to ${allClusterRegionsFile}"

# Write per-cluster network CIDRs (one CIDR per line, aligned with cluster index)
typeset -a clusterNetworkCidrsArr=() machineNetworkCidrsArr=() serviceNetworkCidrsArr=()
for ((i = 1; i <= ACM_SPOKE_CLUSTER_COUNT; i++)); do
    ResolveSpokeCidrs "${i}"
    clusterNetworkCidrsArr+=("${clusterNetworkCidr}")
    machineNetworkCidrsArr+=("${machineNetworkCidr}")
    serviceNetworkCidrsArr+=("${serviceNetworkCidr}")
done
printf '%s\n' "${clusterNetworkCidrsArr[@]}" > "${SHARED_DIR}/managed-cluster-cluster-network-cidrs"
printf '%s\n' "${machineNetworkCidrsArr[@]}"  > "${SHARED_DIR}/managed-cluster-machine-network-cidrs"
printf '%s\n' "${serviceNetworkCidrsArr[@]}"  > "${SHARED_DIR}/managed-cluster-service-network-cidrs"
: "Cluster network CIDRs written to ${SHARED_DIR}/managed-cluster-cluster-network-cidrs"
: "Machine network CIDRs written to ${SHARED_DIR}/managed-cluster-machine-network-cidrs"
: "Service network CIDRs written to ${SHARED_DIR}/managed-cluster-service-network-cidrs"

# Maintain backward compatibility with single-cluster workflows
printf '%s\n' "${clusterNamesArr[0]}" > "${SHARED_DIR}/managed-cluster-name"

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

    : "=========================================="
    ResolveSpokeCidrs "${clusterIdx}"

    : "Creating resources for cluster ${clusterIdx}/${ACM_SPOKE_CLUSTER_COUNT}: ${clusterName}"
    : "Region: ${clusterRegion}"
    : "Pod CIDR: ${clusterNetworkCidr}  VPC CIDR: ${machineNetworkCidr}  Service CIDR: ${serviceNetworkCidr}"
    : "=========================================="

    # Create dedicated namespace for the cluster
    # All cluster-specific resources will be created in this namespace
    : "Creating namespace '${clusterName}'"
    oc create namespace "${clusterName}" --dry-run=client -o yaml --save-config | oc apply -f -

    # Create ManagedClusterSet to group this cluster
    # ManagedClusterSet is a cluster-scoped resource (no namespace)
    : "Creating ManagedClusterSet '${clusterName}-set'"
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

    # Bind the ManagedClusterSet to the cluster's namespace
    # This allows the namespace to use the cluster set
    : "Creating ManagedClusterSetBinding '${clusterName}-set'"
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

    # Create AWS credentials secret from cluster profile
    # Uses process substitution to avoid exposing credentials in logs
    : "Creating AWS credentials secret"
    oc -n "${clusterName}" create secret generic acm-aws-secret \
        --type=Opaque \
        --from-file=aws_access_key_id=<(
            typeset _wasTracing=false
            [[ $- == *x* ]] && _wasTracing=true
            set +x
            printf '%s' "$(
                cat "${CLUSTER_PROFILE_DIR}/.awscred" |
                    sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q'
            )"
            [[ "${_wasTracing}" == "true" ]] && set -x
            true
        ) \
        --from-file=aws_secret_access_key=<(
            typeset _wasTracing=false
            [[ $- == *x* ]] && _wasTracing=true
            set +x
            printf '%s' "$(
                cat "${CLUSTER_PROFILE_DIR}/.awscred" |
                    sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q'
            )"
            [[ "${_wasTracing}" == "true" ]] && set -x
            true
        ) \
        --dry-run=client -o yaml --save-config | oc apply -f -

    # Label the secret for ACM credential discovery
    oc label secret acm-aws-secret \
        cluster.open-cluster-management.io/type=aws \
        cluster.open-cluster-management.io/credentials="" \
        -n "${clusterName}" --overwrite \
        --dry-run=client -o yaml | oc apply -f -

    # Create pull-secret for accessing container registries
    : "Creating pull-secret"
    oc -n "${clusterName}" create secret generic pull-secret \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson="${CLUSTER_PROFILE_DIR}/config.json" \
        --dry-run=client -o yaml --save-config | oc apply -f -

    # Create SSH key secrets for node access
    : "Creating SSH public key secret"
    oc -n "${clusterName}" create secret generic ssh-public-key \
        --type=Opaque \
        --from-file=ssh-publickey="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
        --dry-run=client -o yaml --save-config | oc apply -f -

    : "Creating SSH private key secret"
    oc -n "${clusterName}" create secret generic ssh-private-key \
        --type=Opaque \
        --from-file=ssh-privatekey="${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
        --dry-run=client -o yaml --save-config | oc apply -f -

    # Generate OpenShift install-config.yaml
    # install-config is an OpenShift Installer config, NOT a Kubernetes resource,
    # so oc create --dry-run cannot process it (it would fail with "Kind is missing").
    # Build the JSON document directly with jq -cn; all shell values are injected
    # via --arg / --argjson so no shell expansion occurs inside the jq filter.
    # JSON is a valid YAML superset: Hive reads install-config as YAML and accepts
    # the JSON form without any conversion step.
    : "Creating install-config for region '${clusterRegion}'"
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
        --arg clusterNetCidr "${clusterNetworkCidr}" \
        --arg machineNetCidr "${machineNetworkCidr}" \
        --arg serviceNetCidr "${serviceNetworkCidr}" \
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
                "clusterNetwork": [{"cidr": $clusterNetCidr, "hostPrefix": 23}],
                "machineNetwork": [{"cidr": $machineNetCidr}],
                "serviceNetwork": [$serviceNetCidr]
            },
            "platform": {"aws": {"region": $region}},
            "sshKey": $sshKey
        }' > "${installConfigFile}"

    # Store install-config as a secret for Hive to consume
    : "Creating install-config secret"
    oc -n "${clusterName}" create secret generic install-config \
        --type Opaque \
        --from-file install-config.yaml="${installConfigFile}" \
        --dry-run=client -o yaml --save-config | oc apply -f -

    # Create ClusterDeployment - this is the main Hive resource
    # that triggers the actual cluster installation
    # Note: Uses the cluster-specific region from the lease
    : "Creating ClusterDeployment '${clusterName}' in region '${clusterRegion}'"
    {
        oc create -f - --dry-run=client -o json --save-config |
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
    } 0<<'ocEOF' | oc apply -f -
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

    # Create ManagedCluster - registers the cluster with ACM hub
    # hubAcceptsClient: true auto-approves the cluster registration
    : "Creating ManagedCluster '${clusterName}'"
    {
        oc create -f - --dry-run=client -o json --save-config |
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
    } 0<<'ocEOF' | oc apply -f -
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

    # Create KlusterletAddonConfig - enables ACM features on the spoke cluster
    # This configures which ACM add-ons are deployed to the spoke
    : "Creating KlusterletAddonConfig '${clusterName}'"
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --arg name "${clusterName}" \
            '
            .metadata.name      = $name |
            .metadata.namespace = $name |
            .spec.clusterName      = $name |
            .spec.clusterNamespace = $name
            ' |
        yq -p json -o yaml eval .
    } 0<<'ocEOF' | oc apply -f -
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

    : "Resources created for cluster ${clusterName} in region ${clusterRegion}"
    true
}

#=====================
# Function: WaitForClusterProvisioned
#=====================
# Waits for a ClusterDeployment to reach Provisioned=True status.
# This indicates the cluster installation has completed successfully.
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
    typeset -i timeoutSecs=$(( ACM_SPOKE_INSTALL_TIMEOUT_MINUTES * 60 ))

    : "Polling ClusterDeployment '${clusterName}' for Provisioned=True (timeout=${ACM_SPOKE_INSTALL_TIMEOUT_MINUTES}m, poll=${pollInterval}s)"

    # Run the poll loop in a subshell so that SECONDS=0 does not clobber the
    # parent script's elapsed-time counter. Exit codes propagate normally.
    (
        SECONDS=0
        typeset cdJson provisioned stopReason stopMessage

        while (( SECONDS < timeoutSecs )); do
            cdJson="$(JsonGet "${clusterName}" clusterdeployment "${clusterName}")" || {
                : "Failed to fetch ClusterDeployment '${clusterName}', will retry..."
                sleep "${pollInterval}"
                continue
            }

            # Check for ProvisionStopped=True first — Hive sets this when installation
            # has permanently failed, so we can fail fast without waiting for the timeout.
            stopReason="$(jq -r '
                .status.conditions[]?
                | select(.type=="ProvisionStopped" and .status=="True")
                | .reason // "N/A"
            ' <<< "${cdJson}")"
            if [[ -n "${stopReason}" ]]; then
                stopMessage="$(jq -r '
                    .status.conditions[]?
                    | select(.type=="ProvisionStopped" and .status=="True")
                    | .message // "N/A"
                ' <<< "${cdJson}")"
                : "Cluster ${clusterIdx} (${clusterName}) - ProvisionStopped=True"
                : "Reason:  ${stopReason}"
                : "Message: ${stopMessage}"
                exit 3
            fi

            # Check Provisioned=True — success path.
            provisioned="$(jq -r '
                .status.conditions[]?
                | select(.type=="Provisioned" and .status=="True")
                | .type
            ' <<< "${cdJson}")"
            if [[ "${provisioned}" == "Provisioned" ]]; then
                : "Cluster ${clusterIdx} (${clusterName}) - ClusterDeployment Provisioned=True"
                exit 0
            fi

            : "Cluster ${clusterIdx} (${clusterName}) - still provisioning (${SECONDS}/${timeoutSecs}s), retrying in ${pollInterval}s..."
            sleep "${pollInterval}"
        done

        # Timed out — log last known conditions for post-mortem
        : "Cluster ${clusterIdx} (${clusterName}) - Timed out after ${SECONDS}s waiting for Provisioned=True (limit=${ACM_SPOKE_INSTALL_TIMEOUT_MINUTES}m)"
        : "Last ClusterDeployment conditions:"
        jq -r '.status.conditions[]? | "  \(.type)=\(.status) reason=\(.reason // "N/A")"' \
            <<< "${cdJson}" >&2
        exit 3
    )
}

#=====================
# Function: ExtractClusterCredentials
#=====================
# Extracts the admin kubeconfig and metadata from a provisioned cluster.
# These are stored in secrets created by Hive after successful provisioning.
#
# Arguments:
#   $1 - clusterName: Name of the cluster
#   $2 - clusterIdx:  Index number of the cluster (1-based)
#
# Output files:
#   - ${SHARED_DIR}/managed-cluster-kubeconfig-{N}    : Admin kubeconfig
#   - ${SHARED_DIR}/managed-cluster-metadata-{N}.json : Cluster metadata
#
ExtractClusterCredentials() {
    typeset clusterName="$1"
    typeset clusterIdx="$2"

    # Get the admin kubeconfig from the secret referenced in ClusterDeployment
    : "Extracting admin kubeconfig for cluster ${clusterIdx}: ${clusterName}"
    typeset adminKubeconfigSecretName
    adminKubeconfigSecretName="$(
        oc -n "${clusterName}" get "ClusterDeployment/${clusterName}" \
            -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}'
    )"

    if [[ -z "${adminKubeconfigSecretName}" ]]; then
        : "Failed to get admin kubeconfig secret name for ${clusterName}"
        exit 1
    fi

    # Decode and save the kubeconfig
    typeset kubeconfigFile="${SHARED_DIR}/managed-cluster-kubeconfig-${clusterIdx}"
    oc -n "${clusterName}" get "Secret/${adminKubeconfigSecretName}" \
        -o jsonpath='{.data.kubeconfig}' |
        base64 -d > "${kubeconfigFile}"

    : "Kubeconfig for cluster ${clusterIdx} saved to ${kubeconfigFile}"

    # Extract cluster metadata (contains infraID, clusterID, etc.)
    typeset metadataSecret
    metadataSecret="$(
        oc -n "${clusterName}" get "ClusterDeployment/${clusterName}" \
            -o jsonpath='{.spec.clusterMetadata.metadataJSONSecretRef.name}'
    )"

    if [[ -z "${metadataSecret}" ]]; then
        : "metadataJSONSecretRef is not set for ${clusterName}; metadata.json may not exist"
    else
        if oc -n "${clusterName}" get secret "${metadataSecret}" 1>/dev/null; then
            typeset metadataFile="${SHARED_DIR}/managed-cluster-metadata-${clusterIdx}.json"
            oc -n "${clusterName}" get secret "${metadataSecret}" \
                -o jsonpath='{.data.metadata\.json}' | base64 -d \
                > "${metadataFile}"
            : "Cluster ${clusterIdx} metadata extracted to ${metadataFile}"
        else
            : "Secret '${metadataSecret}' not found in namespace '${clusterName}';" \
                 "managed-cluster-metadata-${clusterIdx}.json will not be written" >&2
            exit 1
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

: "=========================================="
: "Starting creation of ${ACM_SPOKE_CLUSTER_COUNT} spoke cluster(s)"
: "Regions: ${clusterRegionsArr[*]}"
: "=========================================="

# Declare loop index variable once for all phases
typeset -i idx=0

# Phase 1: Create all cluster resources
# This initiates the provisioning process for all clusters in parallel
# Each cluster is deployed to its corresponding region from the lease
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    idx=$((i + 1))
    CreateClusterResources "${clusterNamesArr[i]}" "${idx}" "${clusterRegionsArr[i]}"
done

: "All cluster resources created. Waiting for provisioning..."

# Phase 2: Wait for all clusters to complete provisioning
# Each cluster typically takes 30-45 minutes to provision
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    idx=$((i + 1))
    WaitForClusterProvisioned "${clusterNamesArr[i]}" "${idx}"
done

: "All clusters provisioned. Extracting credentials..."

# Phase 3: Extract credentials for all provisioned clusters
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    idx=$((i + 1))
    ExtractClusterCredentials "${clusterNamesArr[i]}" "${idx}"
done

# Create symlinks for backward compatibility with single-cluster workflows
# This allows existing steps that expect 'managed-cluster-kubeconfig' to work
ln -sf "managed-cluster-kubeconfig-1" "${SHARED_DIR}/managed-cluster-kubeconfig"
ln -sf "managed-cluster-metadata-1.json" "${SHARED_DIR}/managed-cluster-metadata.json"

# Print summary of created resources
: "=========================================="
: "All ${ACM_SPOKE_CLUSTER_COUNT} spoke cluster(s) provisioned and registered with ACM"
: "=========================================="
for ((i = 0; i < ${#clusterNamesArr[@]}; i++)); do
    idx=$((i + 1))
    : "Cluster ${idx}: ${clusterNamesArr[i]} (Region: ${clusterRegionsArr[i]})"
done
: "=========================================="
: "Cluster names file: ${SHARED_DIR}/managed-cluster-names"
: "Cluster regions file: ${SHARED_DIR}/managed-cluster-regions"
: "Individual cluster name files: ${SHARED_DIR}/managed-cluster-name-1 .. managed-cluster-name-${ACM_SPOKE_CLUSTER_COUNT}"
: "Kubeconfig files: ${SHARED_DIR}/managed-cluster-kubeconfig-1 .. managed-cluster-kubeconfig-${ACM_SPOKE_CLUSTER_COUNT}"
true
