#!/bin/bash
#
# Submariner Install & Configure Script
#
# Installs and configures Submariner for a 1-hub + 2-spoke cluster topology
# using the subctl CLI and Globalnet (supports overlapping CIDRs).
#
# Flow:
#   1. Install tooling: subctl, yq (latest from GitHub releases)
#   2. Prepare AWS security groups on each spoke (open Submariner ports)
#   3. Deploy the Submariner broker on the hub cluster
#   4. Join each spoke cluster to the broker
#   5. Wait for Submariner gateways to become active
#   6. Verify spoke-to-spoke connectivity with subctl verify
#
# Required files in SHARED_DIR (written by acm-interop-p2p-cluster-install):
#   managed-cluster-name-1         : Spoke 1 cluster name
#   managed-cluster-name-2         : Spoke 2 cluster name
#   managed-cluster-kubeconfig-1   : Spoke 1 kubeconfig
#   managed-cluster-kubeconfig-2   : Spoke 2 kubeconfig
#   managed-cluster-metadata-1.json: Spoke 1 Hive metadata (contains infraID and aws.region)
#   managed-cluster-metadata-2.json: Spoke 2 Hive metadata
#
# Environment Variables (from ref.yaml):
#   SUBMARINER_GLOBALNET        : enable Globalnet (default: true)
#   SUBMARINER_GATEWAY_COUNT    : gateways per cluster (default: 1)
#   SUBMARINER_CABLE_DRIVER     : cable driver (default: libreswan)
#   SUBMARINER_HUB_JOINS        : hub also joins broker (default: false)
#   SUBMARINER_BROKER_NAMESPACE : namespace on hub (default: submariner-k8s-broker)
#   SUBMARINER_VERIFY_TIMEOUT   : subctl verify timeout seconds (default: 300)
#

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Script-level variables
#=====================
typeset subctlBin="/tmp/subctl"
typeset yqBin="/tmp/yq"
typeset brokerInfoFile="/tmp/broker-info.subm"

# Number of spoke clusters — fixed at 2 for this step
typeset -i spokeCount=2

# Spoke index arrays populated in LoadSpokeConfig
typeset -a spokeNames=()
typeset -a spokeKubeconfigs=()
typeset -a spokeMetadataFiles=()

#=====================
# Need
#   Verifies a command is available; exits with error if not.
# Arguments:
#   $1 - command name
#=====================
Need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[FATAL] Required command '$1' not found" >&2
        exit 1
    }
    true
}

#=====================
# InstallSubctl
#   Downloads the latest subctl binary from GitHub releases if not already
#   present on PATH. Uses the GitHub releases API to resolve the latest tag.
#=====================
InstallSubctl() {
    if command -v subctl >/dev/null 2>&1; then
        echo "[INFO] subctl already on PATH: $(subctl version 2>/dev/null || true)"
        subctlBin="$(command -v subctl)"
        true
        return
    fi

    typeset version
    version="$(
        curl -fsSL \
            "https://api.github.com/repos/submariner-io/subctl/releases/latest" |
            jq -r '.tag_name'
    )"
    echo "[INFO] Downloading subctl ${version}"

    typeset archive="/tmp/subctl.tar.gz"
    curl -fsSL \
        "https://github.com/submariner-io/subctl/releases/download/${version}/subctl-${version}-linux-amd64.tar.gz" \
        -o "${archive}"
    tar -xzf "${archive}" -C /tmp --wildcards '*/subctl-linux-amd64'
    [[ -f "/tmp/subctl-linux-amd64" ]] && mv "/tmp/subctl-linux-amd64" "${subctlBin}"
    chmod +x "${subctlBin}"
    export PATH="/tmp:${PATH}"
    echo "[INFO] subctl installed: $(subctl version 2>/dev/null || true)"
    true
}

#=====================
# InstallYq
#   Downloads the latest yq binary from GitHub releases if not already present
#   on PATH. yq is used to rename kubeconfig context names before subctl verify.
#=====================
InstallYq() {
    if command -v yq >/dev/null 2>&1; then
        echo "[INFO] yq already on PATH: $(yq --version)"
        yqBin="$(command -v yq)"
        true
        return
    fi

    typeset version
    version="$(
        curl -fsSL \
            "https://api.github.com/repos/mikefarah/yq/releases/latest" |
            jq -r '.tag_name'
    )"
    echo "[INFO] Downloading yq ${version}"

    curl -fsSL \
        "https://github.com/mikefarah/yq/releases/download/${version}/yq_linux_amd64" \
        -o "${yqBin}"
    chmod +x "${yqBin}"
    export PATH="/tmp:${PATH}"
    echo "[INFO] yq installed: $(yq --version)"
    true
}

#=====================
# SetAwsCredentials
#   Exports AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from the cluster
#   profile credential file. Tracing is disabled during extraction to prevent
#   credential leakage into CI logs.
#=====================
SetAwsCredentials() {
    echo "[INFO] Loading AWS credentials from cluster profile"

    [[ $- == *x* ]] && typeset wasTracing=true || typeset wasTracing=false
    set +x

    AWS_ACCESS_KEY_ID="$(
        sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' \
            "${CLUSTER_PROFILE_DIR}/.awscred"
    )"
    AWS_SECRET_ACCESS_KEY="$(
        sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' \
            "${CLUSTER_PROFILE_DIR}/.awscred"
    )"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

    ${wasTracing} && set -x
    echo "[INFO] AWS credentials loaded (key ID ends: ...${AWS_ACCESS_KEY_ID: -4})"
    true
}

#=====================
# LoadSpokeConfig
#   Reads spoke cluster names, kubeconfig paths, and metadata file paths from
#   SHARED_DIR into the script-level arrays. Exits if any required file is missing.
#=====================
LoadSpokeConfig() {
    echo "[INFO] Loading spoke cluster configuration from ${SHARED_DIR}"

    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset metaFile="${SHARED_DIR}/managed-cluster-metadata-${i}.json"

        for f in "${nameFile}" "${kcFile}" "${metaFile}"; do
            if [[ ! -f "${f}" ]]; then
                echo "[ERROR] Required file not found: ${f}" >&2
                exit 1
            fi
        done

        spokeNames+=("$(< "${nameFile}")")
        spokeKubeconfigs+=("${kcFile}")
        spokeMetadataFiles+=("${metaFile}")

        echo "[INFO]   Spoke ${i}: name=${spokeNames[-1]}  kubeconfig=${kcFile}"
    done
    true
}

#=====================
# PrepareAwsCluster
#   Runs 'subctl cloud prepare aws' on a cluster to open the required
#   Submariner UDP ports in the node security groups.
#
# Arguments:
#   $1 - kubeconfig file path
#   $2 - cluster metadata JSON file (contains infraID and aws.region)
#   $3 - cluster name (for logging)
#=====================
PrepareAwsCluster() {
    typeset kc="$1"
    typeset metaFile="$2"
    typeset clusterName="$3"

    typeset infraID
    infraID="$(jq -r '.infraID' "${metaFile}")"
    if [[ -z "${infraID}" || "${infraID}" == "null" ]]; then
        echo "[ERROR] infraID not found in ${metaFile}" >&2
        exit 1
    fi

    typeset region
    region="$(jq -r '.aws.region' "${metaFile}")"
    if [[ -z "${region}" || "${region}" == "null" ]]; then
        echo "[ERROR] aws.region not found in ${metaFile}" >&2
        exit 1
    fi

    echo "[INFO] Preparing AWS security groups for spoke '${clusterName}'"
    echo "[INFO]   infraID=${infraID}  region=${region}"

    "${subctlBin}" cloud prepare aws \
        --kubeconfig "${kc}" \
        --infra-id "${infraID}" \
        --region "${region}" \
        --credentials "${CLUSTER_PROFILE_DIR}/.awscred"

    echo "[INFO] AWS security group preparation complete for '${clusterName}'"
    true
}

#=====================
# DeployBroker
#   Deploys the Submariner broker on the hub cluster.
#   Globalnet is enabled by default to handle overlapping CIDRs between spokes.
#   Outputs broker-info.subm to /tmp for use by JoinCluster.
#=====================
DeployBroker() {
    echo "[INFO] Deploying Submariner broker on hub cluster"

    typeset globalnetFlag=""
    if [[ "${SUBMARINER_GLOBALNET:-true}" == "true" ]]; then
        globalnetFlag="--globalnet"
        echo "[INFO] Globalnet enabled (overlapping CIDR support)"
    fi

    # shellcheck disable=SC2086
    "${subctlBin}" deploy-broker \
        --kubeconfig "${KUBECONFIG}" \
        --namespace "${SUBMARINER_BROKER_NAMESPACE:-submariner-k8s-broker}" \
        ${globalnetFlag} \
        --output-dir /tmp

    if [[ ! -f "${brokerInfoFile}" ]]; then
        echo "[ERROR] broker-info.subm not found after deploy-broker at ${brokerInfoFile}" >&2
        exit 1
    fi

    echo "[INFO] Broker deployed successfully. Broker info: ${brokerInfoFile}"
    true
}

#=====================
# JoinCluster
#   Joins a spoke cluster to the Submariner broker.
#
# Arguments:
#   $1 - spoke kubeconfig file path
#   $2 - spoke cluster name (used as clusterID in Submariner)
#=====================
JoinCluster() {
    typeset kc="$1"
    typeset clusterName="$2"

    echo "[INFO] Joining cluster '${clusterName}' to Submariner broker"

    "${subctlBin}" join \
        --kubeconfig "${kc}" \
        --clusterid "${clusterName}" \
        --natt=false \
        --cable-driver "${SUBMARINER_CABLE_DRIVER:-libreswan}" \
        --gateway-count "${SUBMARINER_GATEWAY_COUNT:-1}" \
        "${brokerInfoFile}"

    echo "[INFO] Cluster '${clusterName}' joined broker successfully"
    true
}

#=====================
# WaitSubmarinerReady
#   Polls until the Submariner gateway on a cluster reports 'active' haStatus,
#   or exits with an error after a 10-minute timeout.
#
# Arguments:
#   $1 - spoke kubeconfig file path
#   $2 - spoke cluster name (for logging)
#=====================
WaitSubmarinerReady() {
    typeset kc="$1"
    typeset clusterName="$2"
    typeset -i maxWait=600
    typeset -i interval=15
    typeset -i elapsed=0

    echo "[INFO] Waiting for Submariner gateway to be active on '${clusterName}'"

    while true; do
        typeset status
        status="$(
            KUBECONFIG="${kc}" oc get gateway \
                -n submariner-operator \
                -o jsonpath='{.items[0].status.haStatus}' 2>/dev/null || echo ""
        )"

        if [[ "${status}" == "active" ]]; then
            echo "[INFO] Submariner gateway is active on '${clusterName}'"
            break
        fi

        if (( elapsed >= maxWait )); then
            echo "[ERROR] Timed out waiting for Submariner gateway on '${clusterName}' (status='${status}')" >&2
            KUBECONFIG="${kc}" oc get gateway -n submariner-operator -o yaml 2>/dev/null || true
            exit 1
        fi

        echo "[INFO]   Gateway status='${status}' on '${clusterName}', waiting ${interval}s (${elapsed}/${maxWait}s elapsed)"
        sleep "${interval}"
        (( elapsed += interval ))
    done
    true
}

#=====================
# VerifyConnectivity
#   Runs 'subctl verify' between two spoke clusters to validate that
#   Submariner tunnels are established and cross-cluster connectivity works.
#
#   subctl verify requires each kubeconfig to have a context name that matches
#   the clusterID. yq is used to rewrite the context name in a temporary copy
#   of each kubeconfig before invoking subctl verify.
#
# Arguments:
#   $1 - kubeconfig for cluster A
#   $2 - kubeconfig for cluster B
#   $3 - cluster A name (becomes context name and clusterID)
#   $4 - cluster B name (becomes context name and clusterID)
#=====================
VerifyConnectivity() {
    typeset kc1="$1"
    typeset kc2="$2"
    typeset clusterID1="$3"
    typeset clusterID2="$4"

    echo "[INFO] Verifying Submariner connectivity: '${clusterID1}' <-> '${clusterID2}'"

    typeset kc1Renamed="/tmp/kubeconfig-${clusterID1}.yaml"
    typeset kc2Renamed="/tmp/kubeconfig-${clusterID2}.yaml"

    cp "${kc1}" "${kc1Renamed}"
    cp "${kc2}" "${kc2Renamed}"

    # Read the current context name from each kubeconfig copy
    typeset ctx1
    typeset ctx2
    ctx1="$(KUBECONFIG="${kc1Renamed}" oc config current-context)"
    ctx2="$(KUBECONFIG="${kc2Renamed}" oc config current-context)"

    # Rename the context entry so subctl verify can address it by clusterID
    "${yqBin}" -i \
        "(.contexts[] | select(.name == \"${ctx1}\") | .name) = \"${clusterID1}\" |
         .current-context = \"${clusterID1}\"" \
        "${kc1Renamed}"

    "${yqBin}" -i \
        "(.contexts[] | select(.name == \"${ctx2}\") | .name) = \"${clusterID2}\" |
         .current-context = \"${clusterID2}\"" \
        "${kc2Renamed}"

    echo "[INFO] Running subctl verify between '${clusterID1}' and '${clusterID2}'"
    "${subctlBin}" verify \
        --kubeconfig "${kc1Renamed}" \
        --toconfig "${kc2Renamed}" \
        --fromcontext "${clusterID1}" \
        --tocontext "${clusterID2}" \
        --connection-timeout "${SUBMARINER_VERIFY_TIMEOUT:-300}" \
        --verbose

    echo "[INFO] Connectivity verification passed: '${clusterID1}' <-> '${clusterID2}'"
    true
}

#=====================
# Main
#=====================

Need oc
Need jq
Need curl

LoadSpokeConfig
SetAwsCredentials
InstallSubctl
InstallYq

typeset -i i

# Prepare AWS security groups on each spoke (hub does not need this)
for ((i = 0; i < spokeCount; i++)); do
    PrepareAwsCluster \
        "${spokeKubeconfigs[i]}" \
        "${spokeMetadataFiles[i]}" \
        "${spokeNames[i]}"
done

DeployBroker

# Join each spoke to the broker
for ((i = 0; i < spokeCount; i++)); do
    JoinCluster "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

# Wait for gateways to become active on both spokes
for ((i = 0; i < spokeCount; i++)); do
    WaitSubmarinerReady "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

# Verify spoke-to-spoke connectivity for all adjacent pairs
# For 2 spokes this is exactly one pair: spoke-1 <-> spoke-2
for ((i = 0; i < spokeCount - 1; i++)); do
    VerifyConnectivity \
        "${spokeKubeconfigs[i]}" \
        "${spokeKubeconfigs[$((i + 1))]}" \
        "${spokeNames[i]}" \
        "${spokeNames[$((i + 1))]}"
done

echo "[INFO] Submariner installation and connectivity verification complete"
true
