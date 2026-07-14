#!/bin/bash
#
# ACM Spoke Cluster Installation on vSphere
#
# Provisions a single OpenShift spoke cluster on vSphere via ACM/Hive
# ClusterDeployment. Intended to be used alongside
# acm-interop-p2p-cluster-install (AWS) in the same job, where the vSphere
# spoke occupies the index defined by ACM_VSPHERE_SPOKE_INDEX (default: 2)
# and the AWS step handles index 1.
#
# Leasing:
#   - VSPHERE_LEASED_RESOURCE: a vsphere-connected-2 quota slice in the format
#     "router.datacenter.vlanid" (e.g. "bcr01a.dal10.1153")
#
# Vault credentials mounted at /var/run/vault/vsphere-ibmcloud-config/:
#   - subnets.json                — VLAN topology: vCenter URL, VIPs, DNS, CIDR
#   - load-vsphere-env-config.sh  — sets vsphere_datacenter, vsphere_datastore,
#                                   vsphere_cluster, VCENTER_AUTH_PATH
#
# Output files (N = ACM_VSPHERE_SPOKE_INDEX):
#   SHARED_DIR/managed-cluster-name-{N}          — cluster name
#   SHARED_DIR/managed-cluster-kubeconfig-{N}    — admin kubeconfig
#   SHARED_DIR/managed-cluster-metadata-{N}.json — Hive metadata
#   Also appends to:
#     SHARED_DIR/managed-cluster-names
#     SHARED_DIR/managed-cluster-cluster-network-cidrs
#     SHARED_DIR/managed-cluster-machine-network-cidrs
#     SHARED_DIR/managed-cluster-service-network-cidrs
#

set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq yq

# =====================
# Helper: Need — assert a CLI tool is in PATH
# =====================
Need() {
    command -v "$1" 1>/dev/null || {
        : "'$1' not found"
        exit 1
    }
    true
}

Need oc
Need curl
Need base64
Need openssl

# =====================
# Input validation
# =====================
[[ -n "${VSPHERE_LEASED_RESOURCE}" ]]
[[ -f "${SHARED_DIR}/metadata.json" ]]
[[ -n "${ACM_VSPHERE_CLUSTER_INITIAL_VERSION}" ]]
[[ -n "${ACM_VSPHERE_SPOKE_INDEX}" ]]

typeset -r SUBNETS_CONFIG=/var/run/vault/vsphere-ibmcloud-config/subnets.json
[[ -f "${SUBNETS_CONFIG}" ]]
[[ -f /var/run/vault/vsphere-ibmcloud-config/load-vsphere-env-config.sh ]]

# =====================
# Parse vSphere lease: "router.datacenter.vlanid" (e.g. bcr01a.dal10.1153)
# =====================
typeset vlanRouter vlanPhydc vlanId primaryRouterHostname vspherePortgroup
vlanRouter="${VSPHERE_LEASED_RESOURCE%%.*}"
vlanPhydc="${VSPHERE_LEASED_RESOURCE#*.}"; vlanPhydc="${vlanPhydc%%.*}"
vlanId="${VSPHERE_LEASED_RESOURCE##*.}"
primaryRouterHostname="${vlanRouter}.${vlanPhydc}"
vspherePortgroup="ci-vlan-${vlanId}"

: "vSphere lease parsed: router=${vlanRouter} dc=${vlanPhydc} vlan=${vlanId} portgroup=${vspherePortgroup}"

if ! jq -e --arg prh "${primaryRouterHostname}" --arg vid "${vlanId}" \
        '.[$prh] | has($vid)' "${SUBNETS_CONFIG}" 1>/dev/null; then
    : "VLAN ${vlanId} not found under ${primaryRouterHostname} in subnets.json"
    exit 1
fi

# =====================
# Read network topology from subnets.json
# =====================
typeset vsphereUrl apiVip ingressVip machineNetCidr
vsphereUrl="$(jq -r --arg prh "${primaryRouterHostname}" --arg vid "${vlanId}" \
    '.[$prh][$vid].virtualcenter' "${SUBNETS_CONFIG}")"
apiVip="$(jq -r --argjson n 2 --arg prh "${primaryRouterHostname}" --arg vid "${vlanId}" \
    '.[$prh][$vid].ipAddresses[$n]' "${SUBNETS_CONFIG}")"
ingressVip="$(jq -r --argjson n 3 --arg prh "${primaryRouterHostname}" --arg vid "${vlanId}" \
    '.[$prh][$vid].ipAddresses[$n]' "${SUBNETS_CONFIG}")"
machineNetCidr="$(jq -r --arg prh "${primaryRouterHostname}" --arg vid "${vlanId}" \
    '.[$prh][$vid].machineNetworkCidr' "${SUBNETS_CONFIG}")"

: "vCenter URL: ${vsphereUrl}"
: "API VIP: ${apiVip}  Ingress VIP: ${ingressVip}"
: "Machine CIDR: ${machineNetCidr}"

# =====================
# Load vCenter credentials and topology
# =====================
# load-vsphere-env-config.sh sets:
#   vsphere_datacenter, vsphere_datastore, vsphere_cluster,
#   vsphere_resource_pool, VCENTER_AUTH_PATH, etc.
typeset vsphere_datacenter vsphere_datastore vsphere_cluster vsphere_resource_pool
typeset VCENTER_AUTH_PATH
# shellcheck disable=SC1091
source /var/run/vault/vsphere-ibmcloud-config/load-vsphere-env-config.sh

# VCENTER_AUTH_PATH contains arrays vcenter_usernames and vcenter_passwords.
typeset -a vcenter_usernames=() vcenter_passwords=()
# shellcheck disable=SC1090
source "${VCENTER_AUTH_PATH}"

# Pick a random account to spread load across service accounts.
typeset -i accountLoc=$(( RANDOM % ${#vcenter_usernames[@]} ))
typeset vsphereUser vspherePassword
vsphereUser="${vcenter_usernames[${accountLoc}]}"
# shellcheck disable=SC2034
vspherePassword="${vcenter_passwords[${accountLoc}]}"

typeset vsphereResourcePool="/${vsphere_datacenter}/host/${vsphere_cluster}/Resources/ipi-ci-clusters"

: "vCenter datacenter: ${vsphere_datacenter}"
: "vCenter cluster: ${vsphere_cluster}"
: "vCenter datastore: ${vsphere_datastore}"
: "vCenter user: ${vsphereUser}"
: "Resource pool: ${vsphereResourcePool}"

# =====================
# Fetch vCenter CA cert for Hive certificatesSecretRef
# openssl s_client fetches whatever the server presents (works for self-signed certs).
# Disable xtrace while the cert is captured so the raw PEM is not duplicated to logs.
# =====================
typeset vcenterCert
[[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
set +x
vcenterCert="$(echo | timeout 10 openssl s_client \
    -connect "${vsphereUrl}:443" -showcerts 2>/dev/null \
    | openssl x509 -outform PEM 2>/dev/null || true)"
[[ "${_wasTracing}" == "true" ]] && set -x

if [[ -z "${vcenterCert}" ]]; then
    : "WARNING: Could not fetch vCenter cert from ${vsphereUrl}:443 — certificatesSecretRef will be empty. Hive may fail cert verification."
fi

# =====================
# Derive cluster name and non-overlapping CIDRs
# =====================
# vSphere spoke uses ACM_VSPHERE_SPOKE_INDEX to compute CIDRs that do not
# overlap with the hub (index 0) or any AWS spoke (indices 1-3).
# Formula mirrors ResolveSpokeCidrs in acm-interop-p2p-cluster-install:
#   clusterNetwork = 10.{128 + idx*4}.0.0/14
#   serviceNetwork = 172.{30 + idx}.0.0/16
#   machineNetwork = from subnets.json (VLAN subnet, separate IP space).
typeset -i spokeIdx="${ACM_VSPHERE_SPOKE_INDEX}"
typeset -i clusterNetBase=$(( 128 + spokeIdx * 4 ))
typeset -i svcNetBase=$(( 30 + spokeIdx ))
typeset clusterNetCidr="10.${clusterNetBase}.0.0/14"
typeset serviceNetCidr="172.${svcNetBase}.0.0/16"

: "Spoke index: ${spokeIdx}"
: "Pod CIDR: ${clusterNetCidr}  Machine CIDR: ${machineNetCidr}  Service CIDR: ${serviceNetCidr}"

# Hub cluster name → unique suffix for spoke name
typeset hubClusterName
hubClusterName="$(jq -r '.clusterName' "${SHARED_DIR}/metadata.json")"
[[ -n "${hubClusterName}" ]]

typeset baseSuffix
baseSuffix="$(printf '%s' "${hubClusterName}" | sha1sum | cut -c1-5)"
typeset clusterName="${ACM_VSPHERE_CLUSTER_NAME_PREFIX}-vs-${baseSuffix}"

: "vSphere spoke cluster name: ${clusterName}"

# Write name files (consistent with AWS install step conventions)
printf '%s\n' "${clusterName}" > "${SHARED_DIR}/managed-cluster-name-${spokeIdx}"
: "Cluster name written to ${SHARED_DIR}/managed-cluster-name-${spokeIdx}"

# Append to batch files (the AWS step creates them; we append our entry)
printf '%s\n' "${clusterName}" >> "${SHARED_DIR}/managed-cluster-names"
printf '%s\n' "${clusterNetCidr}" >> "${SHARED_DIR}/managed-cluster-cluster-network-cidrs"
printf '%s\n' "${machineNetCidr}" >> "${SHARED_DIR}/managed-cluster-machine-network-cidrs"
printf '%s\n' "${serviceNetCidr}" >> "${SHARED_DIR}/managed-cluster-service-network-cidrs"

# =====================
# Resolve ClusterImageSet for target OCP version
# =====================
typeset clusterImagesetName
clusterImagesetName="$(
    oc get clusterimagesets.hive.openshift.io -o json |
    jq -r --arg prefix "img${ACM_VSPHERE_CLUSTER_INITIAL_VERSION}." \
        '.items[].metadata.name | select(startswith($prefix))' |
    sort -V |
    tail -n 1
)"
[[ -n "${clusterImagesetName}" ]]
oc get clusterimageset "${clusterImagesetName}" 1>/dev/null
: "Using cluster image set: ${clusterImagesetName}"

# =====================
# Function: CreateVSphereClusterResources
# Creates all hub-side resources needed to provision the vSphere spoke.
# =====================
CreateVSphereClusterResources() {
    # --- Namespace ---
    oc create namespace "${clusterName}" --dry-run=client -o yaml --save-config | oc apply -f -

    # --- ManagedClusterSet ---
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c --arg name "${clusterName}-set" '.metadata.name = $name'
    } 0<<'ocEOF' | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: placeholder
spec: {}
ocEOF

    # --- ManagedClusterSetBinding ---
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --arg name "${clusterName}-set" \
            --arg ns   "${clusterName}" \
            '.metadata.name = $name | .metadata.namespace = $ns | .spec.clusterSet = $name'
    } 0<<'ocEOF' | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: placeholder
  namespace: placeholder
spec:
  clusterSet: placeholder
ocEOF

    # --- vSphere credentials secret ---
    # username/password kept out of xtrace via process substitution.
    : "Creating vsphere-creds secret"
    oc -n "${clusterName}" create secret generic vsphere-creds \
        --type=Opaque \
        --from-literal=username=<(
            [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
            set +x
            printf '%s' "${vsphereUser}"
            [[ "${_wasTracing}" == "true" ]] && set -x
            true
        ) \
        --from-literal=password=<(
            [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
            set +x
            printf '%s' "${vspherePassword}"
            [[ "${_wasTracing}" == "true" ]] && set -x
            true
        ) \
        --dry-run=client -o yaml --save-config | oc apply -f -

    # --- vSphere CA cert secret ---
    : "Creating vsphere-certs secret"
    if [[ -n "${vcenterCert}" ]]; then
        oc -n "${clusterName}" create secret generic vsphere-certs \
            --from-literal=cacert="${vcenterCert}" \
            --dry-run=client -o yaml --save-config | oc apply -f -
    else
        # Empty secret — Hive will attempt to verify against system trust.
        oc create -f - --dry-run=client -o json --save-config |
        jq -c --arg ns "${clusterName}" \
            '.metadata.namespace = $ns | .metadata.name = "vsphere-certs"' |
        oc apply -f - 0<<'ocEOF'
apiVersion: v1
kind: Secret
metadata:
  name: placeholder
  namespace: placeholder
type: Opaque
data: {}
ocEOF
    fi

    # --- pull-secret ---
    oc -n "${clusterName}" create secret generic pull-secret \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=.dockerconfigjson="${CLUSTER_PROFILE_DIR}/config.json" \
        --dry-run=client -o yaml --save-config | oc apply -f -

    # --- SSH keys ---
    oc -n "${clusterName}" create secret generic ssh-public-key \
        --type=Opaque \
        --from-file=ssh-publickey="${CLUSTER_PROFILE_DIR}/ssh-publickey" \
        --dry-run=client -o yaml --save-config | oc apply -f -

    oc -n "${clusterName}" create secret generic ssh-private-key \
        --type=Opaque \
        --from-file=ssh-privatekey="${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
        --dry-run=client -o yaml --save-config | oc apply -f -

    # --- install-config secret (vSphere OCP 4.13+ format with vcenters/failureDomains) ---
    # Credentials are injected via --arg/--rawfile so they never appear in xtrace
    # (jq filter text is static; only the jq --arg values expand).
    : "Creating install-config secret (vSphere platform, OCP 4.13+ format)"
    oc -n "${clusterName}" create secret generic install-config \
        --type Opaque \
        --from-file install-config.yaml=<(
            [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
            set +x
            jq -cn \
                --arg name          "${clusterName}" \
                --arg domain        "${BASE_DOMAIN}" \
                --arg arch          "${ACM_VSPHERE_ARCH_TYPE}" \
                --argjson cpR       "${ACM_VSPHERE_CP_REPLICAS}" \
                --argjson wkR       "${ACM_VSPHERE_WORKER_REPLICAS}" \
                --arg netType       "${ACM_VSPHERE_NETWORK_TYPE}" \
                --arg server        "${vsphereUrl}" \
                --arg user          "${vsphereUser}" \
                --arg pass          "${vspherePassword}" \
                --arg datacenter    "${vsphere_datacenter}" \
                --arg datastore     "${vsphere_datastore}" \
                --arg cluster       "${vsphere_cluster}" \
                --arg resPool       "${vsphereResourcePool}" \
                --arg portgroup     "${vspherePortgroup}" \
                --arg apiVip        "${apiVip}" \
                --arg ingressVip    "${ingressVip}" \
                --arg clusterNet    "${clusterNetCidr}" \
                --arg machineNet    "${machineNetCidr}" \
                --arg serviceNet    "${serviceNetCidr}" \
                --rawfile sshKey    "${CLUSTER_PROFILE_DIR}/ssh-publickey" \
                '{
                    "apiVersion": "v1",
                    "metadata": {"name": $name},
                    "baseDomain": $domain,
                    "controlPlane": {
                        "architecture": $arch,
                        "hyperthreading": "Enabled",
                        "name": "master",
                        "replicas": $cpR
                    },
                    "compute": [{
                        "architecture": $arch,
                        "hyperthreading": "Enabled",
                        "name": "worker",
                        "replicas": $wkR
                    }],
                    "networking": {
                        "networkType": $netType,
                        "clusterNetwork": [{"cidr": $clusterNet, "hostPrefix": 23}],
                        "machineNetwork": [{"cidr": $machineNet}],
                        "serviceNetwork": [$serviceNet]
                    },
                    "platform": {
                        "vsphere": {
                            "vcenters": [{
                                "datacenters": [$datacenter],
                                "password": $pass,
                                "port": 443,
                                "server": $server,
                                "user": $user
                            }],
                            "failureDomains": [{
                                "name": "generated-failure-domain",
                                "region": "generated-region",
                                "server": $server,
                                "topology": {
                                    "computeCluster": ("/" + $datacenter + "/host/" + $cluster),
                                    "datacenter": $datacenter,
                                    "datastore": ("/" + $datacenter + "/datastore/" + $datastore),
                                    "networks": [$portgroup],
                                    "resourcePool": $resPool
                                },
                                "zone": "generated-zone"
                            }],
                            "apiVIPs": [$apiVip],
                            "ingressVIPs": [$ingressVip]
                        }
                    },
                    "sshKey": ($sshKey | rtrimstr("\n"))
                }'
            [[ "${_wasTracing}" == "true" ]] && set -x
            true
        ) \
        --dry-run=client -o yaml --save-config | oc apply -f -

    # --- ClusterDeployment (platform.vsphere) ---
    : "Creating ClusterDeployment '${clusterName}'"
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --arg name       "${clusterName}" \
            --arg domain     "${BASE_DOMAIN}" \
            --arg clusterSet "${clusterName}-set" \
            --arg imageSet   "${clusterImagesetName}" \
            --arg vcenter    "${vsphereUrl}" \
            --arg datacenter "${vsphere_datacenter}" \
            --arg datastore  "${vsphere_datastore}" \
            --arg cluster    "${vsphere_cluster}" \
            --arg network    "${vspherePortgroup}" \
            --arg apiVip     "${apiVip}" \
            --arg ingressVip "${ingressVip}" \
            '
            .metadata.name                                         = $name       |
            .metadata.namespace                                    = $name       |
            .metadata.labels["cluster.open-cluster-management.io/clusterset"] = $clusterSet |
            .spec.baseDomain                                       = $domain     |
            .spec.clusterName                                      = $name       |
            .spec.platform.vsphere.vCenter                         = $vcenter    |
            .spec.platform.vsphere.datacenter                      = $datacenter |
            .spec.platform.vsphere.defaultDatastore                = $datastore  |
            .spec.platform.vsphere.cluster                         = $cluster    |
            .spec.platform.vsphere.network                         = $network    |
            .spec.platform.vsphere.apiVIP                         = $apiVip     |
            .spec.platform.vsphere.ingressVIP                      = $ingressVip |
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
    cloud: vSphere
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: placeholder
spec:
  baseDomain: placeholder
  clusterName: placeholder
  controlPlaneConfig:
    servingCertificates: {}
  platform:
    vsphere:
      vCenter: placeholder
      datacenter: placeholder
      defaultDatastore: placeholder
      folder: ""
      cluster: placeholder
      network: placeholder
      apiVIP: placeholder
      ingressVIP: placeholder
      credentialsSecretRef:
        name: vsphere-creds
      certificatesSecretRef:
        name: vsphere-certs
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

    # --- ManagedCluster ---
    : "Creating ManagedCluster '${clusterName}'"
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --arg name       "${clusterName}" \
            --arg clusterSet "${clusterName}-set" \
            '
            .metadata.name                                         = $name      |
            .metadata.labels.name                                  = $name      |
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
    cloud: vSphere
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: placeholder
spec:
  hubAcceptsClient: true
ocEOF

    # --- KlusterletAddonConfig ---
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
    cloud: vSphere
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

    : "All resources created for vSphere spoke ${clusterName}"
    true
}

# =====================
# Function: WaitForClusterProvisioned
# =====================
WaitForClusterProvisioned() {
    typeset -i timeoutSecs=$(( ACM_VSPHERE_INSTALL_TIMEOUT_MINUTES * 60 ))
    typeset -i pollInterval=30

    : "Polling ClusterDeployment '${clusterName}' for Provisioned=True (timeout=${ACM_VSPHERE_INSTALL_TIMEOUT_MINUTES}m)"

    (
        SECONDS=0
        typeset cdJson provisioned stopReason stopMessage

        while (( SECONDS < timeoutSecs )); do
            cdJson="$(oc -n "${clusterName}" get "clusterdeployment/${clusterName}" -o json)" || {
                : "Failed to fetch ClusterDeployment, retrying..."
                sleep "${pollInterval}"
                continue
            }

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
                : "ProvisionStopped=True for ${clusterName}"
                : "Reason:  ${stopReason}"
                : "Message: ${stopMessage}"
                exit 3
            fi

            provisioned="$(jq -r '
                .status.conditions[]?
                | select(.type=="Provisioned" and .status=="True")
                | .type
            ' <<< "${cdJson}")"
            if [[ "${provisioned}" == "Provisioned" ]]; then
                : "ClusterDeployment ${clusterName} Provisioned=True"
                exit 0
            fi

            : "Still provisioning (${SECONDS}/${timeoutSecs}s)..."
            sleep "${pollInterval}"
        done

        : "Timed out after ${timeoutSecs}s waiting for ${clusterName} Provisioned=True"
        jq -r '.status.conditions[]? | "  \(.type)=\(.status) reason=\(.reason // "N/A")"' \
            <<< "${cdJson}" >&2
        exit 3
    )
}

# =====================
# Function: ExtractClusterCredentials
# =====================
ExtractClusterCredentials() {
    typeset adminKubeconfigSecretName
    adminKubeconfigSecretName="$(
        oc -n "${clusterName}" get "ClusterDeployment/${clusterName}" \
            -o jsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}'
    )"
    [[ -n "${adminKubeconfigSecretName}" ]]

    typeset kubeconfigFile="${SHARED_DIR}/managed-cluster-kubeconfig-${spokeIdx}"
    oc -n "${clusterName}" get "Secret/${adminKubeconfigSecretName}" \
        -o jsonpath='{.data.kubeconfig}' |
        base64 -d > "${kubeconfigFile}"
    : "Kubeconfig saved to ${kubeconfigFile}"

    typeset metadataSecret
    metadataSecret="$(
        oc -n "${clusterName}" get "ClusterDeployment/${clusterName}" \
            -o jsonpath='{.spec.clusterMetadata.metadataJSONSecretRef.name}' || true
    )"
    if [[ -n "${metadataSecret}" ]] && \
            oc -n "${clusterName}" get secret "${metadataSecret}" 1>/dev/null; then
        typeset metadataFile="${SHARED_DIR}/managed-cluster-metadata-${spokeIdx}.json"
        oc -n "${clusterName}" get secret "${metadataSecret}" \
            -o jsonpath='{.data.metadata\.json}' | base64 -d > "${metadataFile}"
        : "Cluster metadata extracted to ${metadataFile}"
    fi
    true
}

# =====================
# On failure: write diagnostics to ARTIFACT_DIR
# =====================
trap '
    if (( $? )); then
        typeset diagFile="${ARTIFACT_DIR}/vsphere-spoke-${clusterName}-install-failure.txt"
        {
            printf "=== ClusterDeployment status ===\n"
            oc -n "${clusterName}" get clusterdeployment "${clusterName}" -o yaml 2>/dev/null || true
            printf "\n=== ClusterDeployment events ===\n"
            oc -n "${clusterName}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -40 || true
        } > "${diagFile}"
        : "Diagnostics written to ${diagFile}"
    fi
' EXIT

# =====================
# Main: create → wait → extract
# =====================
: "Creating vSphere spoke cluster ${clusterName} (index ${spokeIdx})"
CreateVSphereClusterResources

: "Waiting for provisioning to complete..."
WaitForClusterProvisioned

: "Extracting credentials..."
ExtractClusterCredentials

: "vSphere spoke ${clusterName} provisioned and registered with ACM (index ${spokeIdx})"
true
