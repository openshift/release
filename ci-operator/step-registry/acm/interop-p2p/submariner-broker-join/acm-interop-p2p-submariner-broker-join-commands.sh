#!/bin/bash
#
# Step 2 of 3: Submariner Broker Deploy and Cluster Join
#
# Responsibilities:
#   - Install subctl to /tmp/bin/ (step-local; NOT in SHARED_DIR)
#   - Deploy the Submariner broker on the hub cluster
#   - Join each spoke cluster to the broker (subctl join)
#   - broker-info.subm is kept in /tmp and removed on EXIT via trap
#   - Wait (in order) for: submariner-operator, gateway, routeagent,
#     lighthouse-agent, and lighthouse-coredns to be fully ready on each spoke
#
# Globalnet is intentionally NOT enabled: spokes use non-overlapping pod CIDRs
# (ResolveSpokeCidrs in cluster-install) and KubeVirt CCLM requires direct
# cross-cluster reachability to raw pod IPs (sync controller port 8443).
#   - Wait for OpenShift CoreDNS to include Lighthouse DNS forwarding
#
# WHY subctl is downloaded here (not read from SHARED_DIR):
#   Storing large binaries in SHARED_DIR causes CI operator to fail with
#   "Request entity too large" when serialising SHARED_DIR into a Kubernetes
#   Secret between steps (3 MB limit).  Each step installs its own copy.
#

set -euxo pipefail; shopt -s inherit_errexit

# ── Constants ─────────────────────────────────────────────────────────────────
typeset -r subctlBin="/tmp/bin/subctl"
typeset -r brokerInfoFile="/tmp/broker-info.subm"
typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"
typeset remediateGlobalnet="${SUBMARINER_REMEDIATE_GLOBALNET}"
typeset -i uninstallWaitSecs="${SUBMARINER_UNINSTALL_WAIT_SECS}"

typeset -a spokeKubeconfigsArr=()
typeset -a spokeNamesArr=()

# ── Cleanup — remove broker credentials on EXIT ───────────────────────────────
Cleanup() {
    typeset _wasTracing=false
    [[ $- == *x* ]] && _wasTracing=true
    set +x
    rm -f "${brokerInfoFile}"
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

# ── LoadSpokeConfig — populate spoke arrays from SHARED_DIR ───────────────────
LoadSpokeConfig() {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"

        [ -f "${kcFile}" ]
        [ -f "${nameFile}" ]

        spokeKubeconfigsArr+=("${kcFile}")
        spokeNamesArr+=("$(<"${nameFile}")")
    done
    true
}

# ── SanitizeClusterId — convert any string to a valid RFC 1123 DNS label ──────
SanitizeClusterId() {
    typeset raw="${1:?}"; (($#)) && shift
    typeset id

    id="${raw,,}"
    id="${id//[^a-z0-9-]/-}"
    while [[ "${id}" == *--* ]]; do id="${id//--/-}"; done
    id="${id##-}"
    id="${id:0:63}"
    id="${id%%-}"

    [[ -n "${id}" ]] || { : "Cannot derive DNS label from '${raw}'"; false; }
    printf '%s\n' "${id}"
    true
}

# ── BrokerInfoHasGlobalnet — true when broker-info enables Globalnet ──────────
BrokerInfoHasGlobalnet() {
    typeset brokerFile="${1:?}"; (($#)) && shift

    [[ "$(yq e '."globalnet-enabled"' "${brokerFile}")" == "true" ]]
}

# ── RecoverBrokerInfo — regenerate broker-info.subm from an existing broker ───
RecoverBrokerInfo() {
    rm -f "${brokerInfoFile}"
    (
        cd /tmp
        "${subctlBin}" recover-broker-info \
            --kubeconfig "${KUBECONFIG}"
    )
    [ -f "${brokerInfoFile}" ]
    true
}

# ── ClusterHasGlobalnetDaemonset — Globalnet controller must not be present ───
ClusterHasGlobalnetDaemonset() {
    typeset kubeconfig="${1:?}"; (($#)) && shift

    KUBECONFIG="${kubeconfig}" oc get daemonset submariner-globalnet \
        -n submariner-operator 1>/dev/null
}

# ── UninstallSubmarinerFromCluster — remove Submariner from hub or spoke ──────
UninstallSubmarinerFromCluster() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterLabel="${1:?}"; (($#)) && shift

    if KUBECONFIG="${kubeconfig}" oc get namespace submariner-operator 1>/dev/null; then
        : "Uninstalling Submariner from '${clusterLabel}'"
        "${subctlBin}" uninstall \
            --kubeconfig "${kubeconfig}" \
            --yes
    fi

    if KUBECONFIG="${kubeconfig}" oc get namespace submariner-k8s-broker 1>/dev/null; then
        : "Removing broker namespace on '${clusterLabel}'"
        KUBECONFIG="${kubeconfig}" oc delete namespace submariner-k8s-broker \
            --wait=true --timeout=600s 1>/dev/null || true
    fi

    true
}

# ── RemediateGlobalnetIfPresent — uninstall stale Globalnet before redeploy ───
RemediateGlobalnetIfPresent() {
    typeset -i needsRemediate=0
    typeset -i i

    [[ "${remediateGlobalnet}" == "true" ]] || return 0

    for ((i = 0; i < spokeCount; i++)); do
        if ClusterHasGlobalnetDaemonset "${spokeKubeconfigsArr[i]}"; then
            needsRemediate=1
            break
        fi
    done

    if KUBECONFIG="${KUBECONFIG}" oc get namespace submariner-k8s-broker 1>/dev/null; then
        if RecoverBrokerInfo && BrokerInfoHasGlobalnet "${brokerInfoFile}"; then
            needsRemediate=1
        fi
        rm -f "${brokerInfoFile}"
    fi

    (( needsRemediate )) || return 0

    : "Globalnet detected — uninstalling Submariner from all clusters before no-Globalnet redeploy"

    for ((i = 0; i < spokeCount; i++)); do
        UninstallSubmarinerFromCluster \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeNamesArr[i]}"
    done

    UninstallSubmarinerFromCluster "${KUBECONFIG}" "hub"

    sleep "${uninstallWaitSecs}"
    true
}

# ── DeployBroker — deploy Submariner broker on the hub cluster ────────────────
DeployBroker() {
    rm -f "${brokerInfoFile}"
    (
        cd /tmp
        "${subctlBin}" deploy-broker \
            --kubeconfig "${KUBECONFIG}"
    )
    [ -f "${brokerInfoFile}" ]
    BrokerInfoHasGlobalnet "${brokerInfoFile}" && {
        : "deploy-broker created a Globalnet-enabled broker — CCLM requires Globalnet disabled"
        false
    }
    true
}

# ── EnsureBrokerNoGlobalnet — deploy or reuse broker without Globalnet ────────
EnsureBrokerNoGlobalnet() {
    RemediateGlobalnetIfPresent

    if KUBECONFIG="${KUBECONFIG}" oc get namespace submariner-k8s-broker 1>/dev/null; then
        RecoverBrokerInfo
        BrokerInfoHasGlobalnet "${brokerInfoFile}" && {
            : "Existing hub broker has Globalnet enabled — remediate failed or was disabled"
            false
        }
        : "Reusing existing Submariner broker without Globalnet"
        return 0
    fi

    DeployBroker
    true
}

# ── JoinCluster — join one spoke to the broker ────────────────────────────────
#
# --label-gateway=false: gateway is pre-labeled by cloud prepare + WaitForGatewayNode.
# --globalnet=false: explicit even though broker has Globalnet disabled; subctl
#   join defaults --globalnet to true when broker Globalnet is enabled.
# Without --label-gateway=false, subctl join prompts interactively to pick a worker node in CI.
JoinCluster() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    typeset clusterId
    clusterId="$(SanitizeClusterId "${spokeName}")"

    "${subctlBin}" join \
        --kubeconfig "${kubeconfig}" \
        --clusterid "${clusterId}" \
        --label-gateway=false \
        --globalnet=false \
        "${brokerInfoFile}"

    true
}

# ── WaitForObjectToExist — poll until a Kubernetes resource exists ────────────
WaitForObjectToExist() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset resource="${1:?}"; (($#)) && shift
    typeset namespace="${1:?}"; (($#)) && shift
    typeset -i timeoutSecs="${1:-300}"; (($#)) && shift
    typeset spokeName="${1:-unknown}"; (($#)) && shift

    (
        typeset -i wInt=10
        SECONDS=0
        until KUBECONFIG="${kubeconfig}" oc get "${resource}" -n "${namespace}" 1>/dev/null; do
            if (( SECONDS >= timeoutSecs )); then
                : "${resource} not found in '${namespace}' after ${timeoutSecs}s on '${spokeName}'"
                KUBECONFIG="${kubeconfig}" oc get all -n "${namespace}" || true
                exit 1
            fi
            : "Waiting for ${resource} on '${spokeName}' (${SECONDS}/${timeoutSecs}s)"
            sleep "${wInt}"
        done
        true
    )
    true
}

# ── WaitSubmarinerReady — full component readiness sequence for one spoke ─────
WaitSubmarinerReady() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    KUBECONFIG="${kubeconfig}" oc wait deployment/submariner-operator \
        -n submariner-operator \
        --for=condition=Available \
        --timeout=10m 1>/dev/null || {
        : "submariner-operator not Available on '${spokeName}'"
        KUBECONFIG="${kubeconfig}" oc get all -n submariner-operator || true
        false
    }

    WaitForObjectToExist "${kubeconfig}" daemonset/submariner-gateway submariner-operator 300 "${spokeName}"
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-gateway \
        -n submariner-operator --timeout=10m 1>/dev/null

    WaitForObjectToExist "${kubeconfig}" daemonset/submariner-routeagent submariner-operator 300 "${spokeName}"
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-routeagent \
        -n submariner-operator --timeout=20m 1>/dev/null

    WaitForObjectToExist "${kubeconfig}" deployment/submariner-lighthouse-agent submariner-operator 300 "${spokeName}"
    KUBECONFIG="${kubeconfig}" oc rollout status deployment/submariner-lighthouse-agent \
        -n submariner-operator --timeout=10m 1>/dev/null

    WaitForObjectToExist "${kubeconfig}" deployment/submariner-lighthouse-coredns submariner-operator 300 "${spokeName}"
    KUBECONFIG="${kubeconfig}" oc rollout status deployment/submariner-lighthouse-coredns \
        -n submariner-operator --timeout=10m 1>/dev/null

    AssertNoGlobalnetDaemonset "${kubeconfig}" "${spokeName}"

    true
}

# ── AssertNoGlobalnetDaemonset — Globalnet DS must not exist on CCLM spokes ───
AssertNoGlobalnetDaemonset() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    if ClusterHasGlobalnetDaemonset "${kubeconfig}"; then
        : "submariner-globalnet DaemonSet present on '${spokeName}' — incompatible with CCLM pod IP sync"
        false
    fi

    true
}

# ── AssertNoGlobalnetSubnets — remote routes must be pod CIDRs, not 242.x ───
AssertNoGlobalnetSubnets() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    typeset connOutput
    connOutput="$(
        KUBECONFIG="${kubeconfig}" "${subctlBin}" show connections || true
    )"

    if grep -E '242\.[0-9]+\.[0-9]+\.[0-9]+' <<< "${connOutput}"; then
        : "Globalnet subnets (242.x.x.x) advertised on '${spokeName}' — incompatible with CCLM pod IP sync"
        false
    fi

    true
}

# ── WaitForDnsForwardingConfigured — wait for .clusterset.local stub zone ─────
WaitForDnsForwardingConfigured() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    typeset cmName cmNamespace
    if KUBECONFIG="${kubeconfig}" oc get configmap dns-default \
            -n openshift-dns 1>/dev/null; then
        cmName="dns-default"
        cmNamespace="openshift-dns"
    else
        cmName="coredns"
        cmNamespace="kube-system"
    fi

    (
        typeset -i timeout=300 interval=15
        SECONDS=0
        until KUBECONFIG="${kubeconfig}" oc get configmap "${cmName}" -n "${cmNamespace}" \
                -o jsonpath='{.data.Corefile}' | grep -q 'clusterset.local'; do
            if (( SECONDS >= timeout )); then
                : "CoreDNS '${cmName}' not patched with clusterset.local on '${spokeName}' after ${timeout}s"
                KUBECONFIG="${kubeconfig}" oc get configmap "${cmName}" -n "${cmNamespace}" -o yaml || true
                exit 1
            fi
            : "Waiting for clusterset.local in CoreDNS on '${spokeName}' (${SECONDS}/${timeout}s)"
            sleep "${interval}"
        done
        true
    )

    : "Waiting ${SUBMARINER_COREDNS_SETTLE_SECS}s for CoreDNS to propagate clusterset.local forwarding"
    sleep "${SUBMARINER_COREDNS_SETTLE_SECS}"

    # Try OCP dns-default first; fall back to kubeadm coredns — one will not exist.
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/dns-default \
        -n openshift-dns --timeout=5m 1>/dev/null || \
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/coredns \
        -n kube-system --timeout=5m 1>/dev/null || true

    true
}

# ── Main ──────────────────────────────────────────────────────────────────────
command -v oc 1>/dev/null
command -v curl 1>/dev/null
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq yq

LoadSpokeConfig
InstallSubctl

typeset -i submarinerStepRc=0
(
    EnsureBrokerNoGlobalnet

    typeset -i i
    for ((i = 0; i < spokeCount; i++)); do
        JoinCluster "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
    done

    for ((i = 0; i < spokeCount; i++)); do
        WaitSubmarinerReady "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
    done

    for ((i = 0; i < spokeCount; i++)); do
        WaitForDnsForwardingConfigured "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
    done

    for ((i = 0; i < spokeCount; i++)); do
        AssertNoGlobalnetSubnets \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeNamesArr[i]}"
    done
    true
) || submarinerStepRc=$?

if (( submarinerStepRc != 0 )); then
    if [[ "${SUBMARINER_BROKER_JOIN_DEBUG_MODE}" == "true" ]]; then
        : "WARNING: broker-join failed (rc=${submarinerStepRc}); continuing in debug mode"
    else
        exit "${submarinerStepRc}"
    fi
fi
true
