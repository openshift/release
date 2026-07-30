#!/bin/bash
#
# Step 1 of 3: Submariner Cloud Prepare
#
# Responsibilities:
#   - Install subctl to /tmp/bin/ (step-local; NOT in SHARED_DIR)
#   - Run 'subctl cloud prepare aws' on each spoke (always) and on the hub
#     (only when SUBMARINER_VERIFY_HUB_SPOKE=true) to open firewall ports and
#     deploy a gateway node (--gateways 1)
#   - Wait for the gateway node to be Ready and labeled on each prepared cluster
#     before the broker-join step (avoids interactive gateway selection in CI)
#
# SPOKE CLUSTERS (spoke-to-spoke and hub-spoke jobs):
#   PrepareAwsCluster + WaitForGatewayNode — identical to upstream main branch.
#   Spokes use MachineSet-managed dedicated gateway nodes (standard behaviour).
#
# HUB CLUSTER (hub-spoke jobs only, SUBMARINER_VERIFY_HUB_SPOKE=true):
#   PrepareHubAwsCluster + WaitForHubGatewayNode — hub-specific functions.
#   The hub uses c5n.metal bare-metal workers (no MachineSets).  Standard
#   subctl cloud prepare --gateways 1 creates the '<infraID>-submariner-gw-sg' SG
#   with the required IPsec ports and handles security group setup.  On bare-metal
#   clusters with no MachineSets, subctl labels an existing worker node as the
#   gateway.  SG management is handled entirely by subctl.
#
# WHY the hub is optionally prepared (SUBMARINER_VERIFY_HUB_SPOKE=true only):
#   KubeVirt CCLM sync uses raw pod-IP routing (port 8443) between the
#   virt-synchronization-controller on source and destination clusters.
#   For hub↔spoke CCLM the hub must participate in the Submariner mesh so its
#   pods can route to spoke pod IPs and vice versa.
#   Hub metadata is read from ${SHARED_DIR}/metadata.json (standard IPI artifact).
#   For spoke↔spoke CCLM the hub does NOT need to be a Submariner participant,
#   so hub cloud-prepare is skipped to avoid unnecessary ~10-15 min overhead.
#
# WHY binaries are NOT stored in SHARED_DIR:
#   After each step the CI operator serialises SHARED_DIR into a Kubernetes
#   Secret so the next step can access its files.  Kubernetes Secrets have a
#   hard 3 MB request-body limit.  subctl (~50 MB) far exceeds that limit,
#   causing "Request entity too large: limit is 3145728" even when the step
#   script itself succeeds.  Each step therefore installs its own copy of
#   subctl from the internet at step start.
#
# AWS credentials are loaded into ~/.aws/ and removed on EXIT via trap.
# They are never written to SHARED_DIR.
#

set -euxo pipefail; shopt -s inherit_errexit
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

# ── Constants ─────────────────────────────────────────────────────────────────
typeset -r subctlBin="/tmp/bin/subctl"
typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"

typeset awsTmpCreds=""

typeset -a spokeKubeconfigsArr=()
typeset -a spokeMetadataFilesArr=()
typeset -a spokeNamesArr=()

# ── Cleanup — remove AWS credentials on EXIT ──────────────────────────────────
Cleanup() {
    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x
    if [[ -n "${awsTmpCreds}" && -f "${awsTmpCreds}" ]]; then
        rm -f "${awsTmpCreds}"
    fi
    rm -f "${HOME}/.aws/credentials" "${HOME}/.aws/config"
    [[ "${_wasTracing}" == "true" ]] && set -x
}
trap Cleanup EXIT

# ── InstallSubctl — install subctl to /tmp/bin/ ───────────────────────────────
InstallSubctl() {
    mkdir -p /tmp/bin
    if [[ -x "${subctlBin}" ]]; then
        return 0
    fi
    curl -Ls https://get.submariner.io | bash
    cp "${HOME}/.local/bin/subctl" "${subctlBin}"
    chmod +x "${subctlBin}"
    true
}

# ── SetAwsCredentials — write ~/.aws/credentials from cluster profile ────────
#
# Sensitive: set +x wraps credential file writes to prevent xtrace leakage.
SetAwsCredentials() {
    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x

    typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"
    if [[ ! -f "${awsCredFile}" ]]; then
        [[ "${_wasTracing}" == "true" ]] && set -x
        : "AWS credentials file not found: ${awsCredFile}"
        return 1
    fi

    mkdir -p "${HOME}/.aws"
    awsTmpCreds="$(mktemp /tmp/aws-creds-XXXXXX)"

    cat > "${HOME}/.aws/credentials" <<EOF
[default]
aws_access_key_id=$(sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' "${awsCredFile}")
aws_secret_access_key=$(sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' "${awsCredFile}")
EOF

    cat > "${HOME}/.aws/config" <<'EOF'
[default]
region=us-east-1
output=json
EOF
    cp "${HOME}/.aws/credentials" "${awsTmpCreds}"

    [[ "${_wasTracing}" == "true" ]] && set -x
}

# ── LoadSpokeConfig — populate spoke arrays from SHARED_DIR ───────────────────
LoadSpokeConfig() {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset metaFile="${SHARED_DIR}/managed-cluster-metadata-${i}.json"
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"

        [ -f "${kcFile}" ]
        [ -f "${metaFile}" ]
        [ -f "${nameFile}" ]

        spokeKubeconfigsArr+=("${kcFile}")
        spokeMetadataFilesArr+=("${metaFile}")
        spokeNamesArr+=("$(<"${nameFile}")")
    done
    true
}

# ── PrepareAwsCluster — open Submariner firewall ports and deploy gateway ─────
# SPOKE CLUSTERS: identical to upstream main branch.
# Creates a dedicated gateway MachineSet and '<infraID>-submariner' SG.
# Region is extracted from metadata.json so AWS SDK calls target the correct
# region for each spoke, not the us-east-1 default in ~/.aws/config.
PrepareAwsCluster() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset metadataFile="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    typeset spokeRegion
    spokeRegion="$(jq -r '.aws.region // empty' "${metadataFile}" || true)"
    if [[ -n "${spokeRegion}" ]]; then
        export AWS_DEFAULT_REGION="${spokeRegion}"
    else
        : "WARNING: aws.region not found in ${metadataFile}; using current AWS_DEFAULT_REGION for '${spokeName}'"
    fi

    "${subctlBin}" cloud prepare aws \
        --kubeconfig "${kubeconfig}" \
        --ocp-metadata "${metadataFile}" \
        --gateways 1
}

# ── PrepareHubAwsCluster — prepare AWS cloud for Submariner on the hub cluster ─
# HUB ONLY (SUBMARINER_VERIFY_HUB_SPOKE=true): the hub uses c5n.metal bare-metal
# workers with no MachineSets.  subctl cloud prepare --gateways 1 creates the
# '<infraID>-submariner-gw-sg' SG with the required IPsec ports and handles the
# security group setup.  On bare-metal clusters with no MachineSets, subctl labels
# an existing worker node as the gateway.  SG management is handled entirely by
# subctl — no manual rule injection needed.
PrepareHubAwsCluster() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset metadataFile="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    typeset hubRegion
    hubRegion="$(jq -r '.aws.region // empty' "${metadataFile}" || true)"
    if [[ -n "${hubRegion}" ]]; then
        export AWS_DEFAULT_REGION="${hubRegion}"
    else
        : "WARNING: aws.region not found in ${metadataFile}; using current AWS_DEFAULT_REGION for '${clusterName}'"
    fi

    : "Preparing hub '${clusterName}' with --gateways 1"
    "${subctlBin}" cloud prepare aws \
        --kubeconfig "${kubeconfig}" \
        --ocp-metadata "${metadataFile}" \
        --gateways 1
}

# ── WaitForGatewayNode — wait for Submariner MachineSet and gateway-labeled node
# SPOKE CLUSTERS: identical to upstream main branch.
# subctl cloud prepare with --gateways 1 is async: it creates a submariner
# MachineSet and labels the node submariner.io/gateway=true once Ready.
# subctl join prompts interactively when no gateway-labeled node exists yet.
# This function gates the broker-join step until exactly one gateway node exists.
WaitForGatewayNode() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    typeset -i wMax="${SUBMARINER_GATEWAY_WAIT_TIMEOUT}"
    typeset -i wInt=15
    typeset gwMachineSet="" ms allMachineSets

    # Loop 1: wait for a Submariner MachineSet to appear (name contains "submariner")
    SECONDS=0
    until [[ -n "${gwMachineSet}" ]] || (( SECONDS >= wMax )); do
        allMachineSets="$(KUBECONFIG="${kubeconfig}" oc get machineset \
            -n openshift-machine-api \
            -o jsonpath='{.items[*].metadata.name}' || true)"
        for ms in ${allMachineSets}; do
            if [[ "${ms,,}" == *submariner* ]]; then
                gwMachineSet="${ms}"
                break
            fi
        done
        [[ -n "${gwMachineSet}" ]] && break
        : "Waiting for Submariner MachineSet on '${spokeName}' (${SECONDS}/${wMax}s)"
        sleep "${wInt}"
    done
    [[ -n "${gwMachineSet}" ]] || {
        : "No submariner MachineSet on '${spokeName}' after ${wMax}s"
        KUBECONFIG="${kubeconfig}" oc get machineset -n openshift-machine-api || true
        return 1
    }

    # Loop 2: wait for the MachineSet to have readyReplicas=1
    KUBECONFIG="${kubeconfig}" oc wait "machineset/${gwMachineSet}" \
        -n openshift-machine-api \
        --for=jsonpath='{.status.readyReplicas}'=1 \
        --timeout="${wMax}s" || {
        : "Gateway MachineSet '${gwMachineSet}' not ready on '${spokeName}' after ${wMax}s"
        KUBECONFIG="${kubeconfig}" oc get machineset "${gwMachineSet}" \
            -n openshift-machine-api -o wide || true
        return 1
    }

    # Loop 3: wait for exactly 1 node labeled submariner.io/gateway=true
    typeset -i gwCount=0
    SECONDS=0
    until (( gwCount == 1 || SECONDS >= wMax )); do
        gwCount="$(KUBECONFIG="${kubeconfig}" oc get nodes \
            -l submariner.io/gateway=true \
            -o json | jq '.items | length')" || gwCount=0
        (( gwCount == 1 )) && break
        : "Waiting for gateway-labeled node on '${spokeName}' gwCount=${gwCount} (${SECONDS}/${wMax}s)"
        sleep "${wInt}"
    done
    if (( gwCount != 1 )); then
        : "Expected 1 gateway-labeled node on '${spokeName}', found ${gwCount} after ${wMax}s"
        KUBECONFIG="${kubeconfig}" oc get nodes -l submariner.io/gateway=true -o wide || true
        return 1
    fi
}

# ── WaitForHubGatewayNode — wait for gateway-labeled node on bare-metal hub ───
# HUB ONLY: bare-metal hubs have no MachineSets so Loops 1+2 (MachineSet creation
# and readiness) are not applicable.  PrepareHubAwsCluster runs subctl cloud prepare
# --gateways 1 which labels an existing worker node almost immediately after completing.
# This function waits only for the submariner.io/gateway=true label (Loop 3).
WaitForHubGatewayNode() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    typeset -i wMax="${SUBMARINER_GATEWAY_WAIT_TIMEOUT}"
    typeset -i wInt=15

    typeset -i gwCount=0
    SECONDS=0
    until (( gwCount == 1 || SECONDS >= wMax )); do
        gwCount="$(KUBECONFIG="${kubeconfig}" oc get nodes \
            -l submariner.io/gateway=true \
            -o json | jq '.items | length')" || gwCount=0
        (( gwCount == 1 )) && break
        : "Waiting for gateway-labeled node on hub '${clusterName}' gwCount=${gwCount} (${SECONDS}/${wMax}s)"
        sleep "${wInt}"
    done
    if (( gwCount != 1 )); then
        : "Expected 1 gateway-labeled node on hub '${clusterName}', found ${gwCount} after ${wMax}s"
        KUBECONFIG="${kubeconfig}" oc get nodes -l submariner.io/gateway=true -o wide || true
        return 1
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
command -v oc 1>/dev/null
command -v curl 1>/dev/null

[[ -n "${KUBECONFIG}" && -r "${KUBECONFIG}" ]]

# Hub enrollment is only required for hub↔spoke CCLM jobs.
typeset enrollHub="${SUBMARINER_VERIFY_HUB_SPOKE:-false}"

typeset hubMetadataFile="${SHARED_DIR}/metadata.json"
if [[ "${enrollHub}" == "true" ]]; then
    [[ -f "${hubMetadataFile}" ]] || {
        : "Hub metadata file not found at ${hubMetadataFile} — required for hub cloud prepare" >&2
        exit 1
    }
fi

LoadSpokeConfig
InstallSubctl
SetAwsCredentials

typeset -i submarinerStepRc=0
(
    # bash set -e is suppressed inside ( ... ) || ... — use explicit || _cloudFailed=1
    # on every critical call and make (( _cloudFailed == 0 )) the LAST command so
    # the subshell exit code accurately reflects any failure.
    typeset -i _cloudFailed=0
    typeset -i i

    # ── Hub cloud prepare (hub-spoke jobs only) ───────────────────────────────
    # Start hub prepare first so its gateway provision runs concurrently with
    # the spokes (subctl cloud prepare is async; we wait for all clusters below).
    if [[ "${enrollHub}" == "true" ]]; then
        PrepareHubAwsCluster \
            "${KUBECONFIG}" \
            "${hubMetadataFile}" \
            "hub" \
            || _cloudFailed=1
    fi

    # ── Spoke cloud prepare (all jobs) ────────────────────────────────────────
    for ((i = 0; i < spokeCount; i++)); do
        PrepareAwsCluster \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeMetadataFilesArr[i]}" \
            "${spokeNamesArr[i]}" \
            || _cloudFailed=1
    done

    # ── Wait for gateway nodes ────────────────────────────────────────────────
    if [[ "${enrollHub}" == "true" ]]; then
        WaitForHubGatewayNode "${KUBECONFIG}" "hub" || _cloudFailed=1
    fi

    for ((i = 0; i < spokeCount; i++)); do
        WaitForGatewayNode \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeNamesArr[i]}" \
            || _cloudFailed=1
    done

    # LAST command: propagate any critical failure as the subshell exit code.
    (( _cloudFailed == 0 ))
) || submarinerStepRc=$?

if (( submarinerStepRc != 0 )); then
    if [[ "${SUBMARINER_CLOUD_PREPARE_DEBUG_MODE}" == "true" ]]; then
        : "WARNING: cloud-prepare failed (rc=${submarinerStepRc}); continuing in debug mode"
    else
        exit "${submarinerStepRc}"
    fi
fi
true
