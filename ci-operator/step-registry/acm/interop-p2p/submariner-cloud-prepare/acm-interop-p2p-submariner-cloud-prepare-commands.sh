#!/bin/bash
#
# Step 1 of 3: Submariner Cloud Prepare
#
# Responsibilities:
#   - Install subctl to /tmp/bin/ (step-local; NOT in SHARED_DIR)
#   - Run 'subctl cloud prepare aws' on each spoke (always) and on the hub
#     (only when SUBMARINER_VERIFY_HUB_SPOKE=true) to open firewall ports and
#     deploy a dedicated gateway node (--gateways 1)
#   - Wait for the dedicated gateway MachineSet node to be Ready and labeled
#     on prepared clusters before the broker-join step (avoids interactive
#     gateway selection in CI)
#
# WHY the hub is optionally prepared (SUBMARINER_VERIFY_HUB_SPOKE=true only):
#   KubeVirt CCLM sync uses raw pod-IP routing (port 8443) between the
#   virt-synchronization-controller on source and destination clusters.
#   For hub↔spoke CCLM the hub must participate in the Submariner mesh as a
#   full gateway cluster so its pods can route to spoke pod IPs and vice versa.
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
        false
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
    true
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
#
# Uses the default --gateways 1 (one dedicated gateway node per spoke).
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

    true
}

# WaitForGatewayNode — wait for dedicated gateway MachineSet and gateway label
#
# subctl cloud prepare with --gateways 1 is async: it creates a submariner
# MachineSet and labels the node submariner.io/gateway=true once Ready.
# subctl join prompts interactively when no gateway-labeled node exists yet.
# This function gates the broker-join step until exactly one gateway node exists.
#
# Bare-metal clusters (c5n.metal hub, no MachineSets):
#   subctl cloud prepare aws labels an EXISTING worker node as gateway instead
#   of creating a MachineSet-managed one.  Loop 1 + 2 (MachineSet wait) are
#   skipped when the cluster has zero MachineSets; we go straight to Loop 3
#   (gateway-label wait), which subctl satisfies almost immediately.
WaitForGatewayNode() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    typeset -i wMax="${SUBMARINER_GATEWAY_WAIT_TIMEOUT}"
    typeset -i wInt=15

    # Detect whether the cluster uses MachineSets at all (bare-metal hubs don't).
    typeset -i totalMs=0
    totalMs="$(KUBECONFIG="${kubeconfig}" oc get machineset \
        -n openshift-machine-api \
        -o jsonpath='{.items | length}' 2>/dev/null || echo 0)"
    : "'${spokeName}' has ${totalMs} total MachineSets"

    if (( totalMs > 0 )); then
        # Loop 1: wait for a Submariner MachineSet to appear (name contains "submariner")
        typeset gwMachineSet="" ms allMachineSets
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
    else
        : "'${spokeName}' has no MachineSets — subctl labeled an existing node; skipping MachineSet wait"
    fi

    # Loop 3: wait for exactly 1 node labeled submariner.io/gateway=true.
    # This is the authoritative check regardless of MachineSet presence.
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
    # No trailing `true`: exit code = result of the last real check.
}

# ── EnsureGatewaySecurityGroup — attach submariner SG to gateway EC2 instance ──
#
# WHY THIS IS NEEDED (bare-metal hub, no MachineSet):
#   subctl cloud prepare aws creates the '<infraID>-submariner' EC2 security group
#   with rules for UDP 4500 (IPsec NAT-T), UDP 4800 (Submariner encapsulation),
#   and TCP 8080 (metrics).  For MachineSet-managed clusters it patches the
#   MachineSet providerSpec so NEW gateway instances launch with the SG attached.
#   For bare-metal clusters with no MachineSets, subctl labels an EXISTING worker
#   node but does NOT modify the instance's security groups, so incoming UDP 4500
#   (IPsec data packets from the spoke) is blocked by the default SG.  The IKE
#   handshake (UDP 500 / 4500 with NAT stateful tracking) still completes,
#   making libreswan report 'connected', but actual TCP traffic through the tunnel
#   is silently dropped by AWS on the hub side.
#   Explicitly attaching the SG here fixes this without modifying the cluster.
#
# This function is best-effort: log a warning and return 0 on any failure to
# avoid blocking the CI step for a configuration that may not need it.
EnsureGatewaySecurityGroup() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset metadataFile="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    command -v aws 1>/dev/null || {
        : "WARNING: aws CLI not found — skipping explicit SG attachment for '${clusterName}'"
        return 0
    }

    typeset region
    region="$(jq -r '.aws.region // empty' "${metadataFile}")"
    [[ -n "${region}" ]] || {
        : "WARNING: aws.region not in '${metadataFile}' — skipping SG attachment for '${clusterName}'"
        return 0
    }

    # Only needed when the cluster has no MachineSets (bare-metal).
    typeset -i totalMs=0
    totalMs="$(KUBECONFIG="${kubeconfig}" oc get machineset \
        -n openshift-machine-api \
        -o jsonpath='{.items | length}' 2>/dev/null || echo 0)"
    if (( totalMs > 0 )); then
        : "'${clusterName}' has MachineSets — subctl handles SG attachment; skipping manual attach"
        return 0
    fi

    # Gateway node and its EC2 instance ID (providerID: aws:///az/i-xxxxxxxxxx)
    typeset gatewayNode instanceId
    gatewayNode="$(KUBECONFIG="${kubeconfig}" oc get nodes \
        -l 'submariner.io/gateway=true' \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -n "${gatewayNode}" ]] || {
        : "WARNING: No gateway-labeled node on '${clusterName}' — skipping SG attachment"
        return 0
    }

    instanceId="$(KUBECONFIG="${kubeconfig}" oc get node "${gatewayNode}" \
        -o jsonpath='{.spec.providerID}' 2>/dev/null | sed 's|.*/||' || true)"
    [[ -n "${instanceId}" ]] || {
        : "WARNING: Cannot get EC2 instanceId for '${gatewayNode}' on '${clusterName}'"
        return 0
    }

    : "Hub gateway EC2 instance: '${instanceId}' (node '${gatewayNode}')"

    # Find the VPC of the instance (used to narrow the SG search)
    typeset vpcId
    vpcId="$(AWS_DEFAULT_REGION="${region}" aws ec2 describe-instances \
        --instance-ids "${instanceId}" \
        --query 'Reservations[0].Instances[0].VpcId' \
        --output text 2>/dev/null || true)"

    # Find the submariner security group (subctl names it '<infraID>-submariner')
    typeset smSgId
    smSgId="$(AWS_DEFAULT_REGION="${region}" aws ec2 describe-security-groups \
        --filters \
            "Name=group-name,Values=*submariner*" \
            ${vpcId:+"Name=vpc-id,Values=${vpcId}"} \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || true)"
    [[ -n "${smSgId}" && "${smSgId}" != "None" ]] || {
        : "WARNING: Submariner SG not found in AWS for '${clusterName}' (vpc=${vpcId:-unknown}) — skipping"
        return 0
    }
    : "Submariner security group: '${smSgId}'"

    # Collect current security groups; check if already attached
    typeset -a currentSgIds=()
    typeset sgId
    while IFS= read -r sgId; do
        [[ -n "${sgId}" ]] || continue
        [[ "${sgId}" == "${smSgId}" ]] && {
            : "Submariner SG '${smSgId}' already attached to '${clusterName}' gateway '${instanceId}'"
            return 0
        }
        currentSgIds+=("${sgId}")
    done < <(AWS_DEFAULT_REGION="${region}" aws ec2 describe-instance-attribute \
        --instance-id "${instanceId}" \
        --attribute groupSet \
        --query 'Groups[*].GroupId' \
        --output text 2>/dev/null | tr '\t' '\n' || true)

    : "Attaching submariner SG '${smSgId}' to '${clusterName}' gateway '${instanceId}'"
    AWS_DEFAULT_REGION="${region}" aws ec2 modify-instance-attribute \
        --instance-id "${instanceId}" \
        --groups "${currentSgIds[@]}" "${smSgId}" || {
        : "WARNING: Failed to attach submariner SG '${smSgId}' to '${instanceId}' on '${clusterName}'"
    }
    : "Submariner SG attached — incoming UDP 4500 (IPsec NAT-T) will now be allowed on '${clusterName}'"
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

    if [[ "${enrollHub}" == "true" ]]; then
        # Prepare hub first so its gateway provision runs in parallel with spokes
        # (subctl cloud prepare is async; we wait for all clusters below).
        PrepareAwsCluster \
            "${KUBECONFIG}" \
            "${hubMetadataFile}" \
            "hub" \
            || _cloudFailed=1
    fi

    for ((i = 0; i < spokeCount; i++)); do
        PrepareAwsCluster \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeMetadataFilesArr[i]}" \
            "${spokeNamesArr[i]}" \
            || _cloudFailed=1
    done

    if [[ "${enrollHub}" == "true" ]]; then
        # Wait for hub gateway node before broker-join attempts to use it.
        # For bare-metal hubs (no MachineSets), WaitForGatewayNode now skips
        # the MachineSet loops and goes straight to the gateway-label check.
        WaitForGatewayNode "${KUBECONFIG}" "hub" || _cloudFailed=1

        # Explicitly attach the submariner security group to the hub's bare-metal
        # gateway EC2 instance.  subctl cloud prepare aws creates the SG but
        # does not attach it to instances when there are no MachineSets.
        # Without this, incoming UDP 4500 (IPsec NAT-T data) from the spoke is
        # dropped by the default EC2 security group, causing the IPsec SA to
        # appear 'connected' while all pod-to-pod TCP traffic silently fails.
        # Best-effort: failure here logs a warning but does not fail the step.
        EnsureGatewaySecurityGroup "${KUBECONFIG}" "${hubMetadataFile}" "hub" || true
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
