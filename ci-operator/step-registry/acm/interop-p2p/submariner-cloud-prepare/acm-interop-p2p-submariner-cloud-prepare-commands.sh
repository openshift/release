#!/bin/bash
#
# Step 1 of 3: Submariner Cloud Prepare
#
# Responsibilities:
#   - Install subctl to /tmp/bin/ (step-local; NOT in SHARED_DIR)
#   - Run 'subctl cloud prepare aws' on each spoke to open firewall ports
#     and deploy a dedicated gateway node (--gateways 1)
#   - Wait for the dedicated gateway MachineSet node to be Ready and labeled
#     before the broker-join step (avoids interactive gateway selection in CI)
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
# Subshell: no parent-context updates needed; xtrace restores automatically.
Cleanup() {
    ( set +x
        [[ -n "${awsTmpCreds}" && -f "${awsTmpCreds}" ]] && rm -f "${awsTmpCreds}" || true
        rm -f "${HOME}/.aws/credentials" "${HOME}/.aws/config" || true
    true )  # always succeed: cleanup must not abort the step's final exit status
}
trap Cleanup EXIT

# ── InstallSubctl — install subctl to /tmp/bin/ ───────────────────────────────
# Downloads directly from GitHub releases and extracts with tar -xJf.
# Requires xz, which is pre-installed in the cli-with-git step image
# (defined in the CI config via dockerfile_literal).
# NOTE: InstallSubctl is duplicated in broker-join and verify command scripts.
# Each step runs in its own container so the binary cannot be shared via /tmp.
# When changing this function, sync the identical copy in those two scripts.
InstallSubctl() {
    mkdir -p /tmp/bin
    [[ -x "${subctlBin}" ]] && return 0

    typeset version="${SUBMARINER_SUBCTL_VERSION:-release-0.24}"

    # Trusted SHA-256 digests for subctl linux/amd64 archives.
    # To add a new version: compute sha256sum of the .tar.xz and add an entry below.
    typeset -A _subctlDigests=(
        [release-0.24]="6c5e2a022dfe7bd1d9628010837767be0e9aba3a06f95b8b57021c6d6669229b"
    )
    typeset expectedSha="${_subctlDigests["${version}"]:-}"
    if [[ -z "${expectedSha}" ]]; then
        : "SUBMARINER_SUBCTL_VERSION=${version} is not in the trusted digest allowlist; add its SHA-256 to _subctlDigests"
        false
    fi

    typeset archiveName="subctl-${version}-linux-amd64.tar.xz"
    typeset tarUrl="https://github.com/submariner-io/subctl/releases/download/subctl-${version}/${archiveName}"
    typeset tmpTar; tmpTar="$(mktemp /tmp/subctl-XXXXXX.tar.xz)"
    typeset tmpDir; tmpDir="$(mktemp -d /tmp/subctl-dir-XXXXXX)"

    curl -fsSL "${tarUrl}" -o "${tmpTar}"
    printf '%s  %s\n' "${expectedSha}" "${tmpTar}" | sha256sum -c -
    tar -xJf "${tmpTar}" -C "${tmpDir}"
    typeset extracted; extracted="$(find "${tmpDir}" -maxdepth 2 -name 'subctl' -type f | head -1)"
    [[ -n "${extracted}" ]] || { echo "ERROR: subctl binary not found in extracted archive ${tmpTar}" >&2; false; }
    cp "${extracted}" "${subctlBin}"
    chmod +x "${subctlBin}"
    rm -rf "${tmpDir}" "${tmpTar}"
    [[ -x "${subctlBin}" ]]
}

# ── SetAwsCredentials — write ~/.aws/credentials from cluster profile ────────
#
# awsTmpCreds (parent-scope) stores a temp file PATH — safe to trace.
# Credential VALUES are written inside a subshell so xtrace never sees them.
SetAwsCredentials() {
    typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"
    [[ -f "${awsCredFile}" ]]

    mkdir -p "${HOME}/.aws"
    awsTmpCreds="$(mktemp /tmp/aws-creds-XXXXXX)"

    # Subshell: credential values written here; xtrace restores automatically on exit.
    ( set +x
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
    true )
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
        false
    }

    # Loop 2: wait for the MachineSet to have readyReplicas=1
    KUBECONFIG="${kubeconfig}" oc wait "machineset/${gwMachineSet}" \
        -n openshift-machine-api \
        --for=jsonpath='{.status.readyReplicas}'=1 \
        --timeout="${wMax}s" || {
        : "Gateway MachineSet '${gwMachineSet}' not ready on '${spokeName}' after ${wMax}s"
        KUBECONFIG="${kubeconfig}" oc get machineset "${gwMachineSet}" \
            -n openshift-machine-api -o wide || true
        false
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
        false
    fi

    true
}

# ── Main ──────────────────────────────────────────────────────────────────────
command -v oc 1>/dev/null
command -v curl 1>/dev/null

LoadSpokeConfig
InstallSubctl
SetAwsCredentials

typeset -i submarinerStepRc=0
(
    typeset -i i
    for ((i = 0; i < spokeCount; i++)); do
        PrepareAwsCluster \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeMetadataFilesArr[i]}" \
            "${spokeNamesArr[i]}"
    done

    for ((i = 0; i < spokeCount; i++)); do
        WaitForGatewayNode \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeNamesArr[i]}"
    done
    true
) || submarinerStepRc=$?

if (( submarinerStepRc != 0 )); then
    if [[ "${SUBMARINER_CLOUD_PREPARE_DEBUG_MODE}" == "true" ]]; then
        : "WARNING: cloud-prepare failed (rc=${submarinerStepRc}); continuing in debug mode"
    else
        exit "${submarinerStepRc}"
    fi
fi
true
