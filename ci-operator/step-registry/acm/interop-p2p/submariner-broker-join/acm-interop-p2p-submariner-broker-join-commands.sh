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
# ALL CLUSTERS (spoke-to-spoke and hub-spoke jobs):
#   After WaitSubmarinerReady, RestartRouteAgent + EnsureNonGatewayOvnRoutes
#   are called on EVERY cluster.  In OCP 4.22 OVN-K IC mode each node owns a
#   local OVN NB DB; Submariner's routeagent only programs spoke-CIDR routes on
#   the GATEWAY node's local ovn_cluster_router — worker nodes get no routes and
#   all cross-cluster pod traffic is silently dropped.  EnsureNonGatewayOvnRoutes
#   reads the NonGatewayRoute CRs and execs into each non-gateway ovnkube-node
#   pod to add the missing ovn_cluster_router entries via ovn-nbctl.
#
# HUB CLUSTER (hub-spoke jobs only, SUBMARINER_VERIFY_HUB_SPOKE=true):
#   Hub join runs the same sequence as spokes, gated by enrollHub.
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

    [[ -n "${id}" ]] || { : "Cannot derive DNS label from '${raw}'"; return 1; }
    printf '%s\n' "${id}"
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
    ) || return 1
    [ -f "${brokerInfoFile}" ]
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
    # Use `if` (not `&&`) so that BrokerInfoHasGlobalnet returning 1 (no globalnet, which
    # is the GOOD path) does not cause the `&&` compound to exit 1 and trigger set -e.
    if BrokerInfoHasGlobalnet "${brokerInfoFile}"; then
        : "deploy-broker created a Globalnet-enabled broker — CCLM requires Globalnet disabled"
        return 1
    fi
}

# ── EnsureBrokerNoGlobalnet — deploy or reuse broker without Globalnet ────────
EnsureBrokerNoGlobalnet() {
    RemediateGlobalnetIfPresent

    if KUBECONFIG="${KUBECONFIG}" oc get namespace submariner-k8s-broker 1>/dev/null; then
        RecoverBrokerInfo
        # Use `if` (not `&&`) — same reason as in DeployBroker above.
        if BrokerInfoHasGlobalnet "${brokerInfoFile}"; then
            : "Existing hub broker has Globalnet enabled — remediate failed or was disabled"
            return 1
        fi
        : "Reusing existing Submariner broker without Globalnet"
        return 0
    fi

    DeployBroker
}

# ── JoinCluster — join one cluster to the broker ──────────────────────────────
#
# --label-gateway=false: gateway is pre-labeled by cloud prepare + WaitForGatewayNode.
# --globalnet=false: explicit even though broker has Globalnet disabled; subctl
#   join defaults --globalnet to true when broker Globalnet is enabled.
# Without --label-gateway=false, subctl join prompts interactively to pick a worker node in CI.
JoinCluster() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    typeset clusterId
    clusterId="$(SanitizeClusterId "${clusterName}")"

    "${subctlBin}" join \
        --kubeconfig "${kubeconfig}" \
        --clusterid "${clusterId}" \
        --label-gateway=false \
        --globalnet=false \
        "${brokerInfoFile}"
}

# ── WaitForObjectToExist — poll until a Kubernetes resource exists ────────────
WaitForObjectToExist() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset resource="${1:?}"; (($#)) && shift
    typeset namespace="${1:?}"; (($#)) && shift
    typeset -i timeoutSecs="${1:-300}"; (($#)) && shift
    typeset clusterName="${1:-unknown}"; (($#)) && shift

    (
        typeset -i wInt=10
        SECONDS=0
        until KUBECONFIG="${kubeconfig}" oc get "${resource}" -n "${namespace}" 1>/dev/null; do
            if (( SECONDS >= timeoutSecs )); then
                : "${resource} not found in '${namespace}' after ${timeoutSecs}s on '${clusterName}'"
                KUBECONFIG="${kubeconfig}" oc get all -n "${namespace}" || true
                exit 1
            fi
            : "Waiting for ${resource} on '${clusterName}' (${SECONDS}/${timeoutSecs}s)"
            sleep "${wInt}"
        done
    ) || return 1
}

# ── WaitSubmarinerReady — full component readiness sequence for one cluster ───
# Uses _smFailed tracking: set -e is suppressed when called from ( ) || ...
# so error handlers do not abort the function automatically.
# Each critical wait uses || _smFailed=1 and the last command is
# (( _smFailed == 0 )) so the caller sees the correct exit code.
WaitSubmarinerReady() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift
    typeset -i _smFailed=0

    KUBECONFIG="${kubeconfig}" oc wait deployment/submariner-operator \
        -n submariner-operator \
        --for=condition=Available \
        --timeout=10m 1>/dev/null || {
        : "submariner-operator not Available on '${clusterName}'"
        KUBECONFIG="${kubeconfig}" oc get all -n submariner-operator || true
        _smFailed=1
    }

    WaitForObjectToExist "${kubeconfig}" daemonset/submariner-gateway \
        submariner-operator 300 "${clusterName}" || _smFailed=1
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-gateway \
        -n submariner-operator --timeout=10m 1>/dev/null || _smFailed=1

    WaitForObjectToExist "${kubeconfig}" daemonset/submariner-routeagent \
        submariner-operator 300 "${clusterName}" || _smFailed=1
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-routeagent \
        -n submariner-operator --timeout=20m 1>/dev/null || _smFailed=1

    WaitForObjectToExist "${kubeconfig}" deployment/submariner-lighthouse-agent \
        submariner-operator 300 "${clusterName}" || _smFailed=1
    KUBECONFIG="${kubeconfig}" oc rollout status deployment/submariner-lighthouse-agent \
        -n submariner-operator --timeout=10m 1>/dev/null || _smFailed=1

    WaitForObjectToExist "${kubeconfig}" deployment/submariner-lighthouse-coredns \
        submariner-operator 300 "${clusterName}" || _smFailed=1
    KUBECONFIG="${kubeconfig}" oc rollout status deployment/submariner-lighthouse-coredns \
        -n submariner-operator --timeout=10m 1>/dev/null || _smFailed=1

    AssertNoGlobalnetDaemonset "${kubeconfig}" "${clusterName}" || _smFailed=1

    (( _smFailed == 0 ))
}

# ── AssertNoGlobalnetDaemonset — Globalnet DS must not exist on CCLM clusters ─
AssertNoGlobalnetDaemonset() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    if ClusterHasGlobalnetDaemonset "${kubeconfig}"; then
        : "submariner-globalnet DaemonSet present on '${clusterName}' — incompatible with CCLM pod IP sync"
        return 1
    fi
}

# ── AssertNoGlobalnetSubnets — remote routes must be pod CIDRs, not 242.x ────
AssertNoGlobalnetSubnets() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    typeset connOutput
    connOutput="$(
        KUBECONFIG="${kubeconfig}" "${subctlBin}" show connections || true
    )"

    if grep -E '242\.[0-9]+\.[0-9]+\.[0-9]+' <<< "${connOutput}"; then
        : "Globalnet subnets (242.x.x.x) advertised on '${clusterName}' — incompatible with CCLM pod IP sync"
        return 1
    fi
}

# ── WaitForDnsForwardingConfigured — wait for .clusterset.local stub zone ─────
WaitForDnsForwardingConfigured() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

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
                : "CoreDNS '${cmName}' not patched with clusterset.local on '${clusterName}' after ${timeout}s"
                KUBECONFIG="${kubeconfig}" oc get configmap "${cmName}" -n "${cmNamespace}" -o yaml || true
                exit 1
            fi
            : "Waiting for clusterset.local in CoreDNS on '${clusterName}' (${SECONDS}/${timeout}s)"
            sleep "${interval}"
        done
    ) || return 1

    : "Waiting ${SUBMARINER_COREDNS_SETTLE_SECS}s for CoreDNS to propagate clusterset.local forwarding"
    sleep "${SUBMARINER_COREDNS_SETTLE_SECS}"

    # Try OCP dns-default first; fall back to kubeadm coredns — one will not exist.
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/dns-default \
        -n openshift-dns --timeout=5m 1>/dev/null || \
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/coredns \
        -n kube-system --timeout=5m 1>/dev/null || true
}

# ── RestartRouteAgent — restart routeagent DaemonSet to re-program OVN flows ──
# Called after WaitSubmarinerReady to ensure the routeagent has a clean state
# after all Submariner components are running and NonGatewayRoute CRs have been
# created by the gateway.  The routeagent starts early (before tunnels establish)
# and its initial OVN-K flow programming may be incomplete.
RestartRouteAgent() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    : "Restarting submariner-routeagent on '${clusterName}' to re-program OVN routing flows"
    KUBECONFIG="${kubeconfig}" oc rollout restart daemonset/submariner-routeagent \
        -n submariner-operator 1>/dev/null
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-routeagent \
        -n submariner-operator --timeout=10m 1>/dev/null
}

# ── EnsureNonGatewayOvnRoutes — inject missing OVN cluster-router routes ──────
# ROOT CAUSE (OCP 4.22 OVN-K IC mode):
#   In OVN-K Interconnect (IC) mode each node owns a LOCAL OVN NB database.
#   Submariner's routeagent programs spoke-CIDR routes only into the GATEWAY
#   node's local ovn_cluster_router.  Non-gateway nodes' local OVN NB DBs have
#   NO routes for the remote cluster CIDRs, so ALL cross-cluster pod traffic is
#   silently dropped — even though "subctl show connections" reports "connected".
#   This causes Ncat: TIMEOUT for every subctl verify connectivity test.
#
# FIX:
#   Read the NonGatewayRoute CRs (created by the gateway routeagent after subctl
#   join) to discover the IC transit next-hop and remote CIDRs, then exec into
#   each non-gateway node's ovnkube-node pod and add the missing routes:
#     ovn-nbctl lr-route-add ovn_cluster_router <remoteCIDR> <ICTransitNexthop>
#   The IC transit next-hop (e.g. 100.88.0.x) is already reachable on each
#   worker node — it is the gateway node's IC zone transit-switch IP as
#   advertised in the NGR CR's spec.nextHops field.
EnsureNonGatewayOvnRoutes() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset clusterName="${1:?}"; (($#)) && shift

    : "EnsureNonGatewayOvnRoutes: injecting missing OVN routes on non-gateway nodes of '${clusterName}'"

    # Wait up to 120 s for NonGatewayRoute CRs to be created by the gateway routeagent
    typeset -i ngrCount=0 ngrWait=0
    until (( ngrCount > 0 || ngrWait >= 120 )); do
        ngrCount=$(KUBECONFIG="${kubeconfig}" oc get nongatewayroutes.submariner.io \
            -n submariner-operator --no-headers 2>/dev/null | wc -l || true)
        (( ngrCount > 0 )) && break
        sleep 10
        (( ngrWait += 10 ))
        : "  Waiting for NonGatewayRoute CRs on '${clusterName}' (${ngrWait}/120 s)"
    done

    if (( ngrCount == 0 )); then
        : "  No NonGatewayRoute CRs on '${clusterName}' after 120 s — skipping OVN route injection"
        return 0
    fi

    # Extract IC transit next-hop and all remote CIDRs from all NGR CRs
    typeset nextHop ngrJson
    typeset -a remoteCIDRs=()
    ngrJson=$(KUBECONFIG="${kubeconfig}" oc get nongatewayroutes.submariner.io \
        -n submariner-operator -o json 2>/dev/null)
    nextHop=$(echo "${ngrJson}" | jq -r '.items[0].spec.nextHops[0] // empty')
    mapfile -t remoteCIDRs < <(
        echo "${ngrJson}" | jq -r '.items[].spec.remoteCIDRs[]' 2>/dev/null | sort -u || true
    )

    if [[ -z "${nextHop}" ]] || (( ${#remoteCIDRs[@]} == 0 )); then
        : "  NGR data incomplete (nextHop='${nextHop}', CIDRs=${#remoteCIDRs[@]}) on '${clusterName}' — skipping"
        return 0
    fi

    : "  Remote CIDRs to route: ${remoteCIDRs[*]}"
    : "  IC transit next-hop (gateway): ${nextHop}"

    # Get all non-gateway node names
    typeset -a nonGwNodes=()
    mapfile -t nonGwNodes < <(
        KUBECONFIG="${kubeconfig}" oc get nodes \
            -l '!submariner.io/gateway' \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
    )

    if (( ${#nonGwNodes[@]} == 0 )); then
        : "  No non-gateway nodes on '${clusterName}' — nothing to patch"
        return 0
    fi

    typeset node ovnkubePod cidr addOk
    typeset -i _injFailed=0 _injTotal=0
    for node in "${nonGwNodes[@]}"; do
        ovnkubePod=$(KUBECONFIG="${kubeconfig}" oc get pod \
            -n openshift-ovn-kubernetes \
            -l app=ovnkube-node \
            --field-selector "spec.nodeName=${node}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

        [[ -z "${ovnkubePod}" ]] && {
            : "  No ovnkube-node pod on '${node}' — skipping"
            continue
        }

        for cidr in "${remoteCIDRs[@]}"; do
            (( _injTotal++ ))
            : "  ${node}: ovn_cluster_router ${cidr} → ${nextHop}"
            addOk=false
            # Try ovnkube-controller first (OCP 4.19+), then fall back to ovnkube-node
            if KUBECONFIG="${kubeconfig}" oc exec \
                    -n openshift-ovn-kubernetes "${ovnkubePod}" \
                    -c ovnkube-controller -- \
                    ovn-nbctl --no-leader-only --may-exist lr-route-add \
                    ovn_cluster_router "${cidr}" "${nextHop}" 2>/dev/null; then
                addOk=true
            elif KUBECONFIG="${kubeconfig}" oc exec \
                    -n openshift-ovn-kubernetes "${ovnkubePod}" \
                    -c ovnkube-node -- \
                    ovn-nbctl --no-leader-only --may-exist lr-route-add \
                    ovn_cluster_router "${cidr}" "${nextHop}" 2>/dev/null; then
                addOk=true
            fi

            if [[ "${addOk}" != "true" ]]; then
                (( _injFailed++ ))
                echo "  ERROR: ovn-nbctl lr-route-add failed for ${cidr} on '${node}'" >&2
                continue
            fi

            # Read-back: verify the route is actually present in the local NB DB.
            # lr-route-add exits 0 for --may-exist even when the route was already removed
            # by a reconciliation loop; a read-back confirms the route survived injection.
            typeset _routePresent
            _routePresent=$(KUBECONFIG="${kubeconfig}" oc exec \
                -n openshift-ovn-kubernetes "${ovnkubePod}" \
                -c ovnkube-controller -- \
                ovn-nbctl --no-leader-only find Logical_Router_Static_Route \
                "ip_prefix=${cidr}" 2>/dev/null \
                | grep -c "${nextHop}" || \
                KUBECONFIG="${kubeconfig}" oc exec \
                -n openshift-ovn-kubernetes "${ovnkubePod}" \
                -c ovnkube-node -- \
                ovn-nbctl --no-leader-only find Logical_Router_Static_Route \
                "ip_prefix=${cidr}" 2>/dev/null \
                | grep -c "${nextHop}" || echo "0")

            if (( _routePresent == 0 )); then
                (( _injFailed++ ))
                echo "  ERROR: route ${cidr}→${nextHop} not found in NB DB after injection on '${node}' — likely cleared by reconciliation" >&2
            else
                : "  ${node}: route ${cidr}→${nextHop} confirmed present in NB DB"
            fi
        done
    done

    : "EnsureNonGatewayOvnRoutes '${clusterName}': ${_injFailed} failed of ${_injTotal} route-node pairs"
    (( _injFailed == 0 ))
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
    # bash set -e is suppressed inside ( ... ) || ... — use explicit || _brokerFailed=1
    # on every critical call and make (( _brokerFailed == 0 )) the LAST command so
    # the subshell exit code accurately reflects any failure.
    typeset -i _brokerFailed=0
    typeset -i i

    EnsureBrokerNoGlobalnet || _brokerFailed=1

    # ── Hub join (hub-spoke jobs only) ────────────────────────────────────────
    # Join hub first — its gateway was prepared by cloud-prepare using hub
    # kubeconfig + ${SHARED_DIR}/metadata.json. Hub must be a Submariner
    # participant for hub↔spoke pod-IP routing (CCLM sync port 8443).
    if [[ "${enrollHub}" == "true" ]]; then
        JoinCluster "${KUBECONFIG}" "hub" || _brokerFailed=1
    fi

    # ── Spoke join (all jobs) ─────────────────────────────────────────────────
    for ((i = 0; i < spokeCount; i++)); do
        JoinCluster "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}" || _brokerFailed=1
    done

    # ── Wait for Submariner components ────────────────────────────────────────
    if [[ "${enrollHub}" == "true" ]]; then
        WaitSubmarinerReady "${KUBECONFIG}" "hub" || _brokerFailed=1
    fi

    for ((i = 0; i < spokeCount; i++)); do
        WaitSubmarinerReady "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}" || _brokerFailed=1
    done

    # ── Wait for DNS forwarding ───────────────────────────────────────────────
    if [[ "${enrollHub}" == "true" ]]; then
        WaitForDnsForwardingConfigured "${KUBECONFIG}" "hub" || _brokerFailed=1
    fi

    for ((i = 0; i < spokeCount; i++)); do
        WaitForDnsForwardingConfigured "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}" \
            || _brokerFailed=1
    done

    # ── Assert no Globalnet subnets ───────────────────────────────────────────
    if [[ "${enrollHub}" == "true" ]]; then
        AssertNoGlobalnetSubnets "${KUBECONFIG}" "hub" || _brokerFailed=1
    fi

    for ((i = 0; i < spokeCount; i++)); do
        AssertNoGlobalnetSubnets \
            "${spokeKubeconfigsArr[i]}" \
            "${spokeNamesArr[i]}" \
            || _brokerFailed=1
    done

    # ── Routeagent restart (all clusters) ────────────────────────────────────
    # Restart to give the routeagent a clean start after all components are
    # running and NonGatewayRoute CRs have been created by the gateway.
    for ((i = 0; i < spokeCount; i++)); do
        RestartRouteAgent "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}" || _brokerFailed=1
    done

    if [[ "${enrollHub}" == "true" ]]; then
        RestartRouteAgent "${KUBECONFIG}" "hub" || _brokerFailed=1
    fi

    # ── Inject missing OVN cluster-router routes on non-gateway nodes ─────────
    # In OCP 4.22 OVN-K IC mode each node has its own local OVN NB DB.
    # Submariner's routeagent only programs spoke-CIDR routes on the GATEWAY
    # node's local ovn_cluster_router; worker nodes get nothing.  Without these
    # routes all cross-cluster pod traffic is silently dropped, causing
    # Ncat: TIMEOUT in subctl verify even when tunnels show "connected".
    # EnsureNonGatewayOvnRoutes reads the NGR CRs and execs into each non-gateway
    # ovnkube-node pod to add the missing routes.  Now includes post-injection
    # read-back verification and explicit failure counting.  Still best-effort
    # here (|| true): failure is logged to stderr but does NOT block broker-join
    # since the verify step repeats injection as belt-and-suspenders.  Any
    # read-back failures will produce clear ERROR lines visible in the CI log.
    for ((i = 0; i < spokeCount; i++)); do
        EnsureNonGatewayOvnRoutes \
            "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}" || true
    done

    if [[ "${enrollHub}" == "true" ]]; then
        EnsureNonGatewayOvnRoutes "${KUBECONFIG}" "hub" || true
    fi

    # NOTE: AllowCclmSyncIngress (NetworkPolicy for CCLM sync ingress from remote
    # pod CIDRs) is intentionally NOT called here. IPsec tunnels are not yet confirmed
    # established at this point, so gateways.submariner.io has no connection entries
    # and AllowCclmSyncIngress would silently skip (no remote CIDRs to allow).
    # The call is made in the verify step AFTER WaitForConnectionsEstablished confirms
    # all tunnels are connected and the gateway CRs contain full CIDR data.

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
