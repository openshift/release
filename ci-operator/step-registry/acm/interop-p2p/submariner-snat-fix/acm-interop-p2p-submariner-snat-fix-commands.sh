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

# ── Constants ─────────────────────────────────────────────────────────────────
typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"
typeset -i settleSecs="${SUBMARINER_SNAT_FIX_SETTLE_SECS}"

typeset -a spokeKubeconfigsArr=()
typeset -a spokeNamesArr=()

# ── LoadSpokeConfig — populate spoke arrays from SHARED_DIR ──────────────────
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

# ── GetRemoteSubnets — discover the other spokes' pod+service CIDRs ──────────
# Reads Submariner Endpoint CRs from the given spoke's submariner-operator
# namespace, filters out the local cluster, and prints each remote subnet on
# its own line.
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

# ── GetLocalClusterID — read the cluster_id from the local Endpoint CR ───────
GetLocalClusterID() {
    typeset kubeconfig="${1:?}"

    KUBECONFIG="${kubeconfig}" oc get endpoints.submariner.io \
        -n submariner-operator \
        -o json \
    | jq -r --arg gw "$(KUBECONFIG="${kubeconfig}" \
            oc get nodes -l submariner.io/gateway=true \
            -o jsonpath='{.items[0].metadata.name}')" \
        '.items[]
         | select(.spec.private_ip == ($gw | split(".") | map(tonumber) | @sh)
                  or (.metadata.name | test($gw | split(".")[0])))
         | .spec.cluster_id' \
    | head -1
}

# ── InjectNftablesOnGateway — add remote subnets to the SNAT exemption set ───
# Uses "oc debug node" to run nft on the gateway node's host network.
# The nftables table family is "inet" (confirmed on OCP 4.22; the
# mgmtport-no-snat-subnets-v4 set lives in family inet, table ovn-kubernetes).
InjectNftablesOnGateway() {
    typeset kubeconfig="${1:?}"
    typeset gatewayNode="${2:?}"
    typeset nftElements="${3:?}"  # comma-separated, e.g. "10.132.0.0/14, 172.31.0.0/16"

    : "InjectNftablesOnGateway: node='${gatewayNode}' elements='${nftElements}'"

    KUBECONFIG="${kubeconfig}" oc debug "node/${gatewayNode}" \
        --quiet -- chroot /host \
        nft add element inet ovn-kubernetes mgmtport-no-snat-subnets-v4 \
        "{ ${nftElements} }" 2>&1 | grep -v '^$' || true

    : "InjectNftablesOnGateway: verifying set on '${gatewayNode}'"
    KUBECONFIG="${kubeconfig}" oc debug "node/${gatewayNode}" \
        --quiet -- chroot /host \
        nft list set inet ovn-kubernetes mgmtport-no-snat-subnets-v4 \
        2>/dev/null || true
}

# ── ApplySnatFix — inject nftables exemptions on every gateway of one spoke ──
ApplySnatFix() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    : "ApplySnatFix: spoke='${spokeName}'"

    # Determine this spoke's own cluster ID from its local Endpoint CRs.
    typeset localClusterID
    localClusterID="$(KUBECONFIG="${kubeconfig}" \
        oc get endpoints.submariner.io \
        -n submariner-operator \
        -o json \
        | jq -r '.items[] | select(.spec.private_ip != null)
                  | .spec.cluster_id' \
        | sort -u \
        | grep "${spokeName}" \
        | head -1)"

    if [[ -z "${localClusterID}" ]]; then
        # Fallback: derive from the endpoint name (always contains cluster ID)
        localClusterID="$(KUBECONFIG="${kubeconfig}" \
            oc get endpoints.submariner.io \
            -n submariner-operator \
            -o jsonpath='{.items[0].spec.cluster_id}')"
    fi

    : "ApplySnatFix: localClusterID='${localClusterID}'"

    # Collect remote subnets across all remote spokes (newline-separated).
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

    # Find ALL gateway nodes on this spoke (there may be more than one
    # in a HA Submariner setup, though typically only one is active).
    typeset gatewayNodes
    mapfile -t gatewayNodes < <(KUBECONFIG="${kubeconfig}" \
        oc get nodes \
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

    # Brief settle so the nftables rules take effect before the caller
    # runs subctl verify or starts migration.
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

true
