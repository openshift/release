#!/bin/bash
#
# Submariner SNAT Workaround for OVN-Kubernetes IC mode
#
# Ref: ACM-22805, ACM-24786, ACM-36927
# Ref: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.13/html/release_notes/acm-release-notes#source-ip-ocp-ovnk
#
# Root cause: On OCP 4.22 nightly with OVN-K IC mode, the
# mgmtport-snat nftables chain rewrites the source IP of cross-cluster
# traffic arriving at each spoke's gateway node.  The routeagent sets
# k8s.ovn.org/node-ingress-snat-exclude-subnets on the gateway Node
# object, but OVN-K on OCP 4.22 nightly does NOT reconcile that annotation
# into the mgmtport-no-snat-subnets-v4 nftables set.
#
# Fix: Directly inject each spoke's remote peer CIDRs into the
# mgmtport-no-snat-subnets-v4 set (family: inet, table: ovn-kubernetes)
# on every gateway node of that spoke, using "oc debug node".
#
# NOTE: The ConfigMap (enable-snat-handler) + routeagent-restart approach
# is intentionally NOT used here.  Restarting submariner-routeagent
# re-publishes the Endpoint CR on the broker; the remote gateway detects
# the change and re-initiates NAT discovery, which can break the IPsec
# tunnel for minutes (or permanently if the gateways are in different
# VPCs with UDP/4800 asymmetry).  Direct nftables injection avoids all
# of that by not touching the Submariner control plane at all.
#
# Applied to every spoke cluster. Idempotent: safe to re-run.
#

set -uo pipefail; shopt -s inherit_errexit

# ── Bootstrap: ensure required tools are present ─────────────────────────────
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

# ── Constants ─────────────────────────────────────────────────────────────────
typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"
typeset -i settleSecs="${SUBMARINER_SNAT_FIX_SETTLE_SECS}"

typeset -a spokeKubeconfigsArr=()
typeset -a spokeNamesArr=()
typeset -a _tmpKubeconfigsToClean=()

# ── LoadSpokeConfig — populate spoke arrays from SHARED_DIR ──────────────────
# CI spoke kubeconfigs can have 'namespace: ci-op-XXXXXXXX' in their current
# context.  That namespace does not exist on the spoke cluster, which causes
# oc to fail namespace-validation before executing ANY command (even cluster-
# scoped ones like "oc get nodes").  We create a temp copy of each kubeconfig
# with the context namespace patched to 'default' to avoid this.
LoadSpokeConfig() {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"

        [ -f "${kcFile}" ]
        [ -f "${nameFile}" ]

        typeset tmpKc
        tmpKc="$(mktemp -t submariner-snat-fix-kc-XXXXXX)"
        _tmpKubeconfigsToClean+=("${tmpKc}")
        cp "${kcFile}" "${tmpKc}"
        # Use kubectl (not oc) here to avoid triggering oc's own namespace
        # validation while we are patching the context namespace.
        kubectl --kubeconfig="${tmpKc}" config set-context \
            "$(kubectl --kubeconfig="${tmpKc}" config current-context)" \
            --namespace=default > /dev/null

        spokeKubeconfigsArr+=("${tmpKc}")
        spokeNamesArr+=("$(<"${nameFile}")")
    done
    true
}

# ── GetLocalClusterID — find the cluster_id of this spoke's own endpoint ─────
# Matches on the gateway node's short hostname (e.g. "ip-10-1-99-33") which
# Submariner stores in spec.hostname of the local Endpoint CR.
GetLocalClusterID() {
    typeset kubeconfig="${1:?}"

    typeset gwNode
    gwNode="$(KUBECONFIG="${kubeconfig}" oc get nodes \
        -l submariner.io/gateway=true \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        | head -1)"

    # Strip domain suffix: "ip-10-1-99-33.us-east-2.compute.internal" → "ip-10-1-99-33"
    typeset gwShort="${gwNode%%.*}"

    KUBECONFIG="${kubeconfig}" oc get endpoints.submariner.io \
        -n submariner-operator \
        -o json \
    | jq -r --arg host "${gwShort}" \
        '.items[] | select(.spec.hostname == $host) | .spec.cluster_id' \
    | head -1
}

# ── GetRemoteSubnets — list every subnet from non-local endpoints ─────────────
# Output: one subnet per line (e.g. "10.132.0.0/14\n172.31.0.0/16")
GetRemoteSubnets() {
    typeset kubeconfig="${1:?}"
    typeset localClusterID="${2:?}"

    KUBECONFIG="${kubeconfig}" oc get endpoints.submariner.io \
        -n submariner-operator \
        -o json \
    | jq -r --arg local "${localClusterID}" \
        '.items[]
         | select(.spec.cluster_id != $local)
         | .spec.subnets[]'
}

# ── InjectNftablesOnGateway — add remote subnets to the SNAT exemption set ───
# Uses "oc debug node" to run nft on the gateway node's host network.
# Family is "inet" (confirmed on OCP 4.22; mgmtport-no-snat-subnets-v4 lives
# in family inet, table ovn-kubernetes).
InjectNftablesOnGateway() {
    typeset kubeconfig="${1:?}"
    typeset gatewayNode="${2:?}"
    typeset nftElements="${3:?}"  # comma-separated, e.g. "10.132.0.0/14, 172.31.0.0/16"

    : "InjectNftablesOnGateway: node='${gatewayNode}' elements='${nftElements}'"

    KUBECONFIG="${kubeconfig}" oc debug "node/${gatewayNode}" \
        --quiet --to-namespace=default -- chroot /host \
        nft add element inet ovn-kubernetes mgmtport-no-snat-subnets-v4 \
        "{ ${nftElements} }" 2>&1 | grep -v '^$' || true

    : "InjectNftablesOnGateway: verifying set on '${gatewayNode}'"
    KUBECONFIG="${kubeconfig}" oc debug "node/${gatewayNode}" \
        --quiet --to-namespace=default -- chroot /host \
        nft list set inet ovn-kubernetes mgmtport-no-snat-subnets-v4 \
        2>/dev/null || true
}

# ── ApplySnatFix — inject nftables exemptions on every gateway of one spoke ──
ApplySnatFix() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    : "ApplySnatFix: spoke='${spokeName}'"

    # Determine this spoke's own cluster ID from its gateway node hostname.
    typeset localClusterID
    localClusterID="$(GetLocalClusterID "${kubeconfig}")"

    if [[ -z "${localClusterID}" ]]; then
        # Fallback: match cluster_id by spoke name (cluster names contain spokeName)
        localClusterID="$(KUBECONFIG="${kubeconfig}" oc get endpoints.submariner.io \
            -n submariner-operator \
            -o jsonpath='{range .items[*]}{.spec.cluster_id}{"\n"}{end}' \
            | grep "${spokeName}" | head -1)"
    fi

    if [[ -z "${localClusterID}" ]]; then
        : "ApplySnatFix: could not determine localClusterID for '${spokeName}' — skipping"
        return 0
    fi

    : "ApplySnatFix: localClusterID='${localClusterID}'"

    # Collect remote subnets (newline-separated).
    typeset remoteSubnetList
    remoteSubnetList="$(GetRemoteSubnets "${kubeconfig}" "${localClusterID}")"

    if [[ -z "${remoteSubnetList}" ]]; then
        : "ApplySnatFix: no remote subnets found for '${spokeName}' — skipping nftables injection"
        return 0
    fi

    # Convert newline list to nft element format: "10.a.b.c/x, 10.d.e.f/y"
    typeset nftElements
    nftElements="$(echo "${remoteSubnetList}" | paste -sd ',' - | sed 's/,/, /g')"
    : "ApplySnatFix: remote subnets for injection: ${nftElements}"

    # Find ALL gateway nodes on this spoke.
    typeset -a gatewayNodes
    mapfile -t gatewayNodes < <(KUBECONFIG="${kubeconfig}" oc get nodes \
        -l submariner.io/gateway=true \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    if [[ ${#gatewayNodes[@]} -eq 0 ]]; then
        : "ApplySnatFix: no gateway nodes found on '${spokeName}' — skipping"
        return 0
    fi

    typeset gwNode
    for gwNode in "${gatewayNodes[@]}"; do
        InjectNftablesOnGateway "${kubeconfig}" "${gwNode}" "${nftElements}"
    done

    sleep "${settleSecs}"

    : "ApplySnatFix: '${spokeName}' complete"
    true
}

# ── Main ──────────────────────────────────────────────────────────────────────
LoadSpokeConfig

typeset -i i
for ((i = 0; i < spokeCount; i++)); do
    ApplySnatFix \
        "${spokeKubeconfigsArr[i]}" \
        "${spokeNamesArr[i]}"
done

typeset _tmpKc
for _tmpKc in "${_tmpKubeconfigsToClean[@]+"${_tmpKubeconfigsToClean[@]}"}"; do
    rm -f "${_tmpKc}"
done

true
