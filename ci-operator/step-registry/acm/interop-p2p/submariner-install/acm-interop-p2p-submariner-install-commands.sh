#!/bin/bash
#
# Submariner Install & Configure Script
#
# Installs and configures Submariner for a 1-hub + 2-spoke cluster topology
# using the subctl CLI and Globalnet (supports overlapping CIDRs).
#
# Reference: https://submariner.io/getting-started/quickstart/openshift/globalnet/
#
# Flow:
#   1. Install tooling: subctl (via https://get.submariner.io), yq
#   2. Prepare AWS security groups on each spoke (subctl cloud prepare aws)
#   3. Deploy the Submariner broker on the hub cluster (subctl deploy-broker --globalnet)
#   4. Join each spoke to the broker (subctl join)
#   5. Wait for Submariner gateways to become active on both spokes
#   6. Verify spoke-to-spoke connectivity with subctl verify
#   7. Verify service discovery: deploy nginx on spoke-2, access it from spoke-1
#      via nginx.default.svc.clusterset.local (mirrors the manual verification
#      steps in the Submariner Globalnet quickstart guide)
#
# Required files in SHARED_DIR (written by acm-interop-p2p-cluster-install):
#   managed-cluster-name-1         : Spoke 1 cluster name
#   managed-cluster-name-2         : Spoke 2 cluster name
#   managed-cluster-kubeconfig-1   : Spoke 1 kubeconfig
#   managed-cluster-kubeconfig-2   : Spoke 2 kubeconfig
#   managed-cluster-metadata-1.json: Spoke 1 Hive metadata (infraID and aws.region)
#   managed-cluster-metadata-2.json: Spoke 2 Hive metadata
#
# Environment Variables (from ref.yaml):
#   SUBMARINER_GLOBALNET        : enable Globalnet (default: true)
#   SUBMARINER_GATEWAY_COUNT    : gateways per cluster (default: 1)
#   SUBMARINER_CABLE_DRIVER     : cable driver (default: libreswan)
#   SUBMARINER_BROKER_NAMESPACE : namespace on hub (default: submariner-k8s-broker)
#   SUBMARINER_VERIFY_TIMEOUT   : subctl verify --connection-timeout seconds (default: 300)
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
#   Installs subctl via the official Submariner install script
#   (https://get.submariner.io). The script places the binary under
#   ~/.local/bin, which is then added to PATH.
#=====================
InstallSubctl() {
    if command -v subctl >/dev/null 2>&1; then
        echo "[INFO] subctl already on PATH: $(subctl version 2>/dev/null || true)"
        subctlBin="$(command -v subctl)"
        true
        return
    fi

    echo "[INFO] Installing subctl via https://get.submariner.io"
    curl -Ls https://get.submariner.io | bash
    export PATH="${PATH}:${HOME}/.local/bin"
    echo "export PATH=\$PATH:${HOME}/.local/bin" >> "${HOME}/.profile"

    if ! command -v subctl >/dev/null 2>&1; then
        echo "[FATAL] subctl not found on PATH after installation" >&2
        exit 1
    fi
    subctlBin="$(command -v subctl)"
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

    # Run in a subshell with cwd=/tmp so broker-info.subm lands in /tmp.
    # --output-dir was removed in recent subctl releases; the file is always
    # written to the current working directory.
    # shellcheck disable=SC2086
    ( cd /tmp && "${subctlBin}" deploy-broker \
        --kubeconfig "${KUBECONFIG}" \
        --namespace "${SUBMARINER_BROKER_NAMESPACE:-submariner-k8s-broker}" \
        ${globalnetFlag} )

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
#   Both kubeconfigs are merged via the KUBECONFIG env var (colon-separated).
#   Context names and user entries are rewritten with yq so each clusterID is
#   unique in the merged config — required by subctl verify's --context flags.
#
#   Pattern follows: https://submariner.io/getting-started/quickstart/openshift/globalnet/
#
# Arguments:
#   $1 - kubeconfig for cluster A (spoke-1)
#   $2 - kubeconfig for cluster B (spoke-2)
#   $3 - cluster A name (becomes --context value and clusterID)
#   $4 - cluster B name (becomes --tocontext value and clusterID)
#=====================
VerifyConnectivity() {
    typeset kc1="$1"
    typeset kc2="$2"
    typeset clusterID1="$3"
    typeset clusterID2="$4"

    echo "[INFO] Verifying Submariner connectivity: '${clusterID1}' <-> '${clusterID2}'"

    # Work on copies so the originals are not modified
    typeset kc1Copy="/tmp/kubeconfig-${clusterID1}.yaml"
    typeset kc2Copy="/tmp/kubeconfig-${clusterID2}.yaml"
    cp "${kc1}" "${kc1Copy}"
    cp "${kc2}" "${kc2Copy}"

    # Rename context names and user entries in each copy so they are unique
    # when the two kubeconfigs are merged. Follows the yq pattern from the
    # Submariner Globalnet quickstart docs.
    "${yqBin}" -i \
        ".contexts[0].name = \"${clusterID1}\" | .current-context = \"${clusterID1}\"" \
        "${kc1Copy}"
    "${yqBin}" -i \
        ".contexts[0].context.user = \"admin-${clusterID1}\" | .users[0].name = \"admin-${clusterID1}\"" \
        "${kc1Copy}"

    "${yqBin}" -i \
        ".contexts[0].name = \"${clusterID2}\" | .current-context = \"${clusterID2}\"" \
        "${kc2Copy}"
    "${yqBin}" -i \
        ".contexts[0].context.user = \"admin-${clusterID2}\" | .users[0].name = \"admin-${clusterID2}\"" \
        "${kc2Copy}"

    echo "[INFO] Running subctl verify between '${clusterID1}' and '${clusterID2}'"
    KUBECONFIG="${kc1Copy}:${kc2Copy}" \
        "${subctlBin}" verify \
            --context "${clusterID1}" \
            --tocontext "${clusterID2}" \
            --only service-discovery,connectivity \
            --connection-timeout "${SUBMARINER_VERIFY_TIMEOUT:-300}" \
            --verbose

    echo "[INFO] Connectivity verification passed: '${clusterID1}' <-> '${clusterID2}'"
    true
}

#=====================
# VerifyNginxConnectivity
#   Validates cross-cluster service discovery by deploying an nginx ClusterIP
#   service on the source cluster, exporting it via 'subctl export service',
#   then running a curl from the target cluster using submariner/nettest.
#
#   This mirrors the manual verification steps from the Submariner Globalnet
#   quickstart: https://submariner.io/getting-started/quickstart/openshift/globalnet/
#
#   The exported service is reachable across clusters as:
#     nginx.default.svc.clusterset.local:8080
#
# Arguments:
#   $1 - kubeconfig for the source cluster (nginx is deployed here; spoke-2)
#   $2 - kubeconfig for the target cluster (curl runs from here; spoke-1)
#   $3 - source cluster name (for logging)
#   $4 - target cluster name (for logging)
#=====================
VerifyNginxConnectivity() {
    typeset kcSource="$1"
    typeset kcTarget="$2"
    typeset sourceCluster="$3"
    typeset targetCluster="$4"

    echo "[INFO] =================================================="
    echo "[INFO] Verifying nginx cross-cluster service discovery"
    echo "[INFO]   nginx deployed on : ${sourceCluster}"
    echo "[INFO]   curl runs from    : ${targetCluster}"
    echo "[INFO] =================================================="

    # Deploy nginx on the source cluster (idempotent via dry-run + apply)
    echo "[INFO] Deploying nginx on '${sourceCluster}'"
    KUBECONFIG="${kcSource}" oc -n default create deployment nginx \
        --image=nginxinc/nginx-unprivileged:stable-alpine \
        --dry-run=client -o yaml | KUBECONFIG="${kcSource}" oc apply -f -

    echo "[INFO] Waiting for nginx deployment to be ready on '${sourceCluster}'"
    KUBECONFIG="${kcSource}" oc -n default rollout status deployment/nginx --timeout=5m

    # Expose as ClusterIP on port 8080 (idempotent)
    KUBECONFIG="${kcSource}" oc -n default expose deployment nginx --port=8080 \
        --dry-run=client -o yaml | KUBECONFIG="${kcSource}" oc apply -f -

    # Export the service for cross-cluster discovery via Submariner
    echo "[INFO] Exporting nginx service on '${sourceCluster}'"
    KUBECONFIG="${kcSource}" "${subctlBin}" export service --namespace default nginx

    # Allow time for ServiceExport to propagate to the remote cluster
    echo "[INFO] Waiting 30s for service export to propagate..."
    sleep 30

    # Clean up any previous nettest pod before running
    KUBECONFIG="${kcTarget}" oc -n default delete pod submariner-nettest \
        --ignore-not-found --grace-period=0 2>/dev/null || true

    # Run a curl from the target cluster using the submariner/nettest image.
    # The service is accessible as: nginx.default.svc.clusterset.local:8080
    echo "[INFO] Running nettest curl from '${targetCluster}' -> nginx.default.svc.clusterset.local:8080"
    KUBECONFIG="${kcTarget}" oc -n default run submariner-nettest \
        --image=quay.io/submariner/nettest \
        --restart=Never \
        -- curl -sS --retry 5 --retry-delay 10 --retry-all-errors \
        "nginx.default.svc.clusterset.local:8080"

    # Poll until the nettest pod completes
    typeset -i elapsed=0
    typeset -i maxWait=180
    typeset podPhase=""
    echo "[INFO] Waiting for nettest pod to complete (up to ${maxWait}s)"
    while (( elapsed < maxWait )); do
        podPhase="$(
            KUBECONFIG="${kcTarget}" oc get pod submariner-nettest -n default \
                -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown"
        )"
        if [[ "${podPhase}" == "Succeeded" ]]; then
            break
        elif [[ "${podPhase}" == "Failed" ]]; then
            echo "[ERROR] nettest pod failed on '${targetCluster}'" >&2
            KUBECONFIG="${kcTarget}" oc -n default logs submariner-nettest >&2 || true
            exit 1
        fi
        echo "[INFO]   nettest pod phase='${podPhase}' (${elapsed}/${maxWait}s elapsed)"
        sleep 15
        (( elapsed += 15 ))
    done

    if [[ "${podPhase}" != "Succeeded" ]]; then
        echo "[ERROR] nettest pod did not complete within ${maxWait}s (phase='${podPhase}')" >&2
        KUBECONFIG="${kcTarget}" oc -n default describe pod submariner-nettest >&2 || true
        exit 1
    fi

    typeset response
    response="$(KUBECONFIG="${kcTarget}" oc -n default logs submariner-nettest)"
    echo "[INFO] nginx response (first 300 chars): ${response:0:300}"
    echo "[INFO] Service discovery confirmed: '${targetCluster}' -> nginx on '${sourceCluster}'"

    # Cleanup test resources
    echo "[INFO] Cleaning up nginx test resources"
    KUBECONFIG="${kcTarget}" oc -n default delete pod submariner-nettest --ignore-not-found
    KUBECONFIG="${kcSource}" oc -n default delete svc nginx --ignore-not-found
    KUBECONFIG="${kcSource}" oc -n default delete deployment nginx --ignore-not-found
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

# Step 6: subctl verify — automated tunnel and service-discovery validation
# For 2 spokes this is exactly one pair: spoke-1 <-> spoke-2
for ((i = 0; i < spokeCount - 1; i++)); do
    VerifyConnectivity \
        "${spokeKubeconfigs[i]}" \
        "${spokeKubeconfigs[$((i + 1))]}" \
        "${spokeNames[i]}" \
        "${spokeNames[$((i + 1))]}"
done

# Step 7: nginx service-discovery verification
# Deploy nginx on spoke-2, export the service, curl it from spoke-1.
# Mirrors the manual ClusterIP verification from the Submariner Globalnet docs.
VerifyNginxConnectivity \
    "${spokeKubeconfigs[1]}" \
    "${spokeKubeconfigs[0]}" \
    "${spokeNames[1]}" \
    "${spokeNames[0]}"

echo "[INFO] Submariner installation and connectivity verification complete"
true
