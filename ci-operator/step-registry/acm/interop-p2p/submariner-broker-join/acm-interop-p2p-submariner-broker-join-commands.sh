#!/bin/bash
#
# Step 2 of 3: Submariner Broker Deploy and Cluster Join
#
# Responsibilities:
#   - Install subctl to /tmp/bin/ (step-local; NOT in SHARED_DIR)
#   - Deploy the Submariner broker on the hub cluster
#   - Join each spoke cluster to the broker (subctl join) — always
#   - Join the HUB cluster itself to the broker (subctl join) — ONLY when
#     SUBMARINER_VERIFY_HUB_SPOKE=true (hub↔spoke CCLM jobs only)
#   - broker-info.subm is kept in /tmp and removed on EXIT via trap
#   - Wait (in order) for: submariner-operator, gateway, routeagent,
#     lighthouse-agent, and lighthouse-coredns to be fully ready on all joined clusters
#
# WHY hub join is conditional (SUBMARINER_VERIFY_HUB_SPOKE=true only):
#   For hub↔spoke CCLM: KubeVirt CCLM uses raw pod-IP routing (port 8443) for
#   virt-synchronization-controller sync. The hub must be a Submariner participant
#   for hub↔spoke pod-IP routing to work. Hub gateway was prepared by cloud-prepare.
#   For spoke↔spoke CCLM: the hub does NOT participate in migrations; joining it
#   adds ~15 min of unnecessary WaitSubmarinerReady overhead to every spoke job.
#
# Globalnet is intentionally NOT enabled: hub and spokes use non-overlapping
# pod CIDRs (ResolveSpokeCidrs in cluster-install) and KubeVirt CCLM requires
# direct cross-cluster reachability to raw pod IPs (sync controller port 8443).
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
    # No trailing `true`: function exit code = subctl join exit code.
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
    # No trailing `true`: function exit code = inner subshell exit code (0=found, 1=timeout).
}

# ── WaitSubmarinerReady — full component readiness sequence for one spoke ─────
# Uses _smFailed tracking: set -e is suppressed when called from ( ) || ...
# so `false`/`exit 1` inside error handlers do not abort the function.
# Each critical wait uses || _smFailed=1 and the function's last command is
# (( _smFailed == 0 )) so the caller sees the correct exit code.
WaitSubmarinerReady() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift
    typeset -i _smFailed=0

    KUBECONFIG="${kubeconfig}" oc wait deployment/submariner-operator \
        -n submariner-operator \
        --for=condition=Available \
        --timeout=10m 1>/dev/null || {
        : "submariner-operator not Available on '${spokeName}'"
        KUBECONFIG="${kubeconfig}" oc get all -n submariner-operator || true
        _smFailed=1
    }

    WaitForObjectToExist "${kubeconfig}" daemonset/submariner-gateway \
        submariner-operator 300 "${spokeName}" || _smFailed=1
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-gateway \
        -n submariner-operator --timeout=10m 1>/dev/null || _smFailed=1

    WaitForObjectToExist "${kubeconfig}" daemonset/submariner-routeagent \
        submariner-operator 300 "${spokeName}" || _smFailed=1
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-routeagent \
        -n submariner-operator --timeout=20m 1>/dev/null || _smFailed=1

    WaitForObjectToExist "${kubeconfig}" deployment/submariner-lighthouse-agent \
        submariner-operator 300 "${spokeName}" || _smFailed=1
    KUBECONFIG="${kubeconfig}" oc rollout status deployment/submariner-lighthouse-agent \
        -n submariner-operator --timeout=10m 1>/dev/null || _smFailed=1

    WaitForObjectToExist "${kubeconfig}" deployment/submariner-lighthouse-coredns \
        submariner-operator 300 "${spokeName}" || _smFailed=1
    KUBECONFIG="${kubeconfig}" oc rollout status deployment/submariner-lighthouse-coredns \
        -n submariner-operator --timeout=10m 1>/dev/null || _smFailed=1

    AssertNoGlobalnetDaemonset "${kubeconfig}" "${spokeName}" || _smFailed=1

    (( _smFailed == 0 ))
}

# ── AssertNoGlobalnetDaemonset — Globalnet DS must not exist on CCLM spokes ───
# Uses `return 1` (not `false`): `false` inside an `if` block is subject to
# set -e suppression and the trailing `true` would override it anyway.
# `return 1` exits the function immediately with exit code 1.
AssertNoGlobalnetDaemonset() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    if ClusterHasGlobalnetDaemonset "${kubeconfig}"; then
        : "submariner-globalnet DaemonSet present on '${spokeName}' — incompatible with CCLM pod IP sync"
        return 1
    fi
}

# ── AllowCclmSyncIngress — NetworkPolicy: cross-cluster pod CIDRs → CNV port ──
# Creates (or updates) a NetworkPolicy in the CNV namespace on each cluster so
# that cross-cluster pod IPs (advertised by the Submariner gateway) are allowed
# to reach all pods in the namespace on SUBMARINER_CCLM_SYNC_PORT (default 8443).
#
# WHY THIS IS NEEDED:
#   OCP's OVN-Kubernetes enforces NetworkPolicies at the pod interface. The CNV
#   operator (HCO) creates restrictive ingress policies in openshift-cnv that
#   only allow intra-namespace traffic by default. Cross-cluster CCLM sync
#   arrives at the virt-synchronization-controller pod from a remote pod CIDR
#   that is NOT a local pod, so OVN-K drops it silently (timeout, not refused).
#   Adding an ipBlock rule for the remote Submariner pod CIDRs makes the sync
#   path explicit and compliant with the existing NetworkPolicy model.
#
# SAFETY: NetworkPolicy rules are additive — this policy does NOT restrict
#   any traffic that was already permitted by existing policies.
AllowCclmSyncIngress() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    typeset cnvNs="${SUBMARINER_CCLM_CNV_NAMESPACE:-openshift-cnv}"
    typeset cclmPort="${SUBMARINER_CCLM_SYNC_PORT:-8443}"

    # Collect remote pod/service CIDRs from active Submariner gateway connections.
    typeset -a remoteCidrs=()
    typeset cidr
    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        remoteCidrs+=("${cidr}")
    done < <(
        KUBECONFIG="${kubeconfig}" oc get gateways.submariner.io \
            -n submariner-operator -o json 2>/dev/null \
            | jq -r '.items[].status.connections[].endpoint.subnets[]?' \
            || true
    )

    if (( ${#remoteCidrs[@]} == 0 )); then
        : "No Submariner remote CIDRs found on '${clusterName}' — skipping CCLM NetworkPolicy"
        return 0
    fi

    : "Creating CCLM ingress NetworkPolicy on '${clusterName}' ns='${cnvNs}' port=${cclmPort} cidrs=[${remoteCidrs[*]}]"

    # Use jq to build valid JSON (avoid heredoc YAML indentation pitfalls).
    # oc apply accepts JSON manifests directly.
    KUBECONFIG="${kubeconfig}" oc apply -f - < <(
        jq -n \
            --arg  ns   "${cnvNs}" \
            --arg  port "${cclmPort}" \
            --argjson cidrs "$(printf '%s\n' "${remoteCidrs[@]}" | jq -R . | jq -s .)" \
            '{
                apiVersion: "networking.k8s.io/v1",
                kind: "NetworkPolicy",
                metadata: {name: "allow-submariner-cclm-sync", namespace: $ns},
                spec: {
                    podSelector: {},
                    policyTypes: ["Ingress"],
                    ingress: [{
                        from: ($cidrs | map({ipBlock: {cidr: .}})),
                        ports: [{protocol: "TCP", port: ($port | tonumber)}]
                    }]
                }
            }'
    ) || {
        : "WARNING: could not apply CCLM sync NetworkPolicy on '${clusterName}' (ns may not exist yet)"
        true
    }

    true
}

# ── AssertNoGlobalnetSubnets — remote routes must be pod CIDRs, not 242.x ───
# Uses `return 1` (not `false`): `false` inside an `if` block is subject to
# set -e suppression and the trailing `true` would override it anyway.
# `return 1` exits the function immediately with exit code 1.
AssertNoGlobalnetSubnets() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    typeset connOutput
    connOutput="$(
        KUBECONFIG="${kubeconfig}" "${subctlBin}" show connections || true
    )"

    if grep -E '242\.[0-9]+\.[0-9]+\.[0-9]+' <<< "${connOutput}"; then
        : "Globalnet subnets (242.x.x.x) advertised on '${spokeName}' — incompatible with CCLM pod IP sync"
        return 1
    fi
}

# ── RestartRouteAgent — restart routeagent DaemonSet to re-program OVN flows ──
# WHY THIS IS NEEDED:
#   The submariner-routeagent starts up during `subctl join` and immediately
#   tries to program OVN-K policy-based routing entries for remote cluster pod
#   CIDRs.  However at join time the IPsec tunnel may not yet be fully
#   established, so the routeagent's initial OVN programming can fail silently
#   (the pod stays Running/Ready because its readiness probe checks the agent
#   process, not the OVN entries).  A restart AFTER the tunnel is confirmed
#   connected and remote CIDRs are known gives the routeagent a clean slate to
#   re-program the correct OVN flows.  Without this, hub↔spoke pod-IP routing
#   (required for CCLM sync port 8443) may be missing even though the gateway
#   shows "connected".
RestartRouteAgent() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    : "Restarting submariner-routeagent on '${clusterName}' to re-program OVN routing flows"
    KUBECONFIG="${kubeconfig}" oc rollout restart daemonset/submariner-routeagent \
        -n submariner-operator 1>/dev/null
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-routeagent \
        -n submariner-operator --timeout=10m 1>/dev/null
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
    # No trailing `true`: function exit code = inner subshell exit code (0=configured, 1=timeout).
}

# ── Main ──────────────────────────────────────────────────────────────────────
command -v oc 1>/dev/null
command -v curl 1>/dev/null
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq yq

[[ -n "${KUBECONFIG}" && -r "${KUBECONFIG}" ]]

# Hub enrollment is only required for hub↔spoke CCLM jobs.
typeset enrollHub="${SUBMARINER_VERIFY_HUB_SPOKE:-false}"

LoadSpokeConfig
InstallSubctl

typeset -i submarinerStepRc=0
(
    # bash set -e is suppressed for all commands inside ( ... ) || ... (the left
    # side of || runs in an "errexit-ignored" context per POSIX/bash).  Functions
    # returning non-zero do NOT abort the subshell automatically. Use explicit
    # || _brokerFailed=1 on every critical call and make (( _brokerFailed == 0 ))
    # the LAST command so the subshell exit code reflects any failure.
    typeset -i _brokerFailed=0
    typeset -i i

    EnsureBrokerNoGlobalnet || _brokerFailed=1

    if [[ "${enrollHub}" == "true" ]]; then
        # Join hub first — its gateway was prepared by cloud-prepare using hub
        # kubeconfig + ${SHARED_DIR}/metadata.json. Hub must be a Submariner
        # participant for hub↔spoke pod-IP routing (CCLM sync port 8443).
        JoinCluster "${KUBECONFIG}" "hub" || _brokerFailed=1
    fi

    for ((i = 0; i < spokeCount; i++)); do
        JoinCluster "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}" || _brokerFailed=1
    done

    if [[ "${enrollHub}" == "true" ]]; then
        WaitSubmarinerReady "${KUBECONFIG}" "hub" || _brokerFailed=1
    fi

    for ((i = 0; i < spokeCount; i++)); do
        WaitSubmarinerReady "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}" || _brokerFailed=1
    done

    if [[ "${enrollHub}" == "true" ]]; then
        WaitForDnsForwardingConfigured "${KUBECONFIG}" "hub" || _brokerFailed=1
    fi

    for ((i = 0; i < spokeCount; i++)); do
        WaitForDnsForwardingConfigured "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}" \
            || _brokerFailed=1
    done

    if [[ "${enrollHub}" == "true" ]]; then
        AssertNoGlobalnetSubnets "${KUBECONFIG}" "hub" || _brokerFailed=1
    fi

    for ((i = 0; i < spokeCount; i++)); do
        AssertNoGlobalnetSubnets \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeNamesArr[i]}" \
            || _brokerFailed=1
    done

    # Restart routeagent on all joined clusters now that tunnels are confirmed
    # connected and remote CIDRs are known.  This forces a fresh OVN routing-flow
    # programming pass, fixing cases where the initial startup raced against
    # tunnel establishment and left OVN entries incomplete (leading to pod-IP
    # routing timeouts even though the gateway shows "connected").
    if [[ "${enrollHub}" == "true" ]]; then
        RestartRouteAgent "${KUBECONFIG}" "hub" || _brokerFailed=1
    fi
    for ((i = 0; i < spokeCount; i++)); do
        RestartRouteAgent "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}" \
            || _brokerFailed=1
    done

    # NOTE: AllowCclmSyncIngress (NetworkPolicy for CCLM sync ingress) is intentionally
    # NOT called here.  At this point the IPsec tunnels are not yet established, so
    # gateways.submariner.io has no connection entries and AllowCclmSyncIngress would
    # silently skip (no remote CIDRs).  The call is made in the verify step AFTER
    # WaitForConnectionsEstablished confirms all tunnels are connected and the gateway
    # CRs contain full CIDR data.

    # LAST command: propagate any critical failure as the subshell exit code.
    (( _brokerFailed == 0 ))
) || submarinerStepRc=$?

if (( submarinerStepRc != 0 )); then
    if [[ "${SUBMARINER_BROKER_JOIN_DEBUG_MODE}" == "true" ]]; then
        : "WARNING: broker-join failed (rc=${submarinerStepRc}); continuing in debug mode"
    else
        exit "${submarinerStepRc}"
    fi
fi
true
