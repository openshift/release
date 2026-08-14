#!/bin/bash
# Submariner compatibility workaround for OVN-K IC per-node-zone mode on OCP 4.21+.
# Fixes four independent Submariner v0.24 gaps with OCP 4.22 OVN-K:
#
#   1. LRP nexthop schema mismatch — routeagent v0.24 writes singular "nexthop" field;
#      OVN 6.x (OCP 4.22) requires plural "nexthops". LRPs are created with empty
#      nexthops; OVN generates no southbound flows; cross-cluster traffic falls through
#      to the Gateway Router, gets SNAT'd and dropped. Fix: delete and re-add each
#      Submariner LRP using ovn-nbctl lr-policy-add, which uses the correct schema.
#      Nexthop: gateway node -> its own ovn-k8s-mp0 IP; worker -> transit switch IP
#      from ip route show table 150 (installed by routeagent independently of LRPs).
#
#   2. Table 149 hairpin on gateway nodes — routeagent installs "default via <nexthop>
#      dev ovn-k8s-mp0" in table 149. ip rule 149 fires before rule 150 (Submariner's
#      xfrm rule), routing outbound cross-cluster SYNs back into OVN in a loop. xfrm
#      never sees the packet; the IPsec SA counter stays flat.
#      Fix: ip route del default table 149 dev ovn-k8s-mp0 on each gateway node.
#
#   3. nftables SNAT — two independent POSTROUTING basechains masquerade cross-cluster
#      src IP, breaking TCP on both the outbound path (all nodes) and the inbound/return
#      path (gateway nodes injecting decrypted packets back into OVN via ovn-k8s-mp0):
#        mgmtport-snat (priority 100)       - masquerades all ovn-k8s-mp0 egress
#        ovn-kube-local-gw-masq (priority 101) - masquerades all pod-subnet egress
#      A "return" in chain 1 does NOT stop chain 2 (independent hooks).
#      Fix: prepend "ip daddr <remote-cidr> return" in both chains on every node.
#      Refs: ACM-22805, CORENET-7418, OCPSTRAT-940; upstream: ovn-kubernetes PR #6030.
#
#   4. mgmtport-no-snat-subnets-v4 set empty on gateway nodes — OVN-K provides this
#      "ip saddr @mgmtport-no-snat-subnets-v4 return" hook but never populates it.
#      Fix: add remote CIDRs to the set (belt-and-suspenders for chain 1 on GW nodes).
#
# CRITICAL: all nftables/ovn-nbctl/ip commands use "oc exec -c ovnkube-controller".
# This container has CAP_NET_ADMIN and runs in the host network namespace.
# "oc debug node -- chroot /host nft" silently fails with "Operation not permitted"
# despite returning exit 0 — every prior CI run applied zero nftables rules.
#
# Does NOT restart routeagent — that re-triggers NAT discovery (UDP/4800) and breaks
# the IPsec tunnel in multi-VPC AWS environments for an extended period.
# Idempotent: safe to re-run.

set -uo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"
typeset -i settleSecs="${SUBMARINER_SNAT_FIX_SETTLE_SECS}"
typeset -a spokeKubeconfigsArr=()
typeset -a spokeNamesArr=()
typeset -a _tmpKubeconfigsToClean=()

# CI kubeconfigs may have a ci-op-XXXXXXXX namespace that doesn't exist on the spoke.
# Patch a temp copy to 'default' to avoid oc namespace-validation failures.
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
        kubectl --kubeconfig="${tmpKc}" config set-context \
            "$(kubectl --kubeconfig="${tmpKc}" config current-context)" \
            --namespace=default > /dev/null
        spokeKubeconfigsArr+=("${tmpKc}")
        spokeNamesArr+=("$(<"${nameFile}")")
    done
    true
}

GetLocalClusterID() {
    typeset kubeconfig="${1:?}"
    typeset gwNode
    gwNode="$(KUBECONFIG="${kubeconfig}" oc get nodes \
        -l submariner.io/gateway=true \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        | head -1)"
    KUBECONFIG="${kubeconfig}" oc get endpoints.submariner.io \
        -n submariner-operator -o json \
    | jq -r --arg host "${gwNode%%.*}" \
        '.items[] | select(.spec.hostname == $host) | .spec.cluster_id' \
    | head -1
}

GetRemoteSubnets() {
    typeset kubeconfig="${1:?}"
    typeset localClusterID="${2:?}"
    KUBECONFIG="${kubeconfig}" oc get endpoints.submariner.io \
        -n submariner-operator -o json \
    | jq -r --arg local "${localClusterID}" \
        '.items[] | select(.spec.cluster_id != $local) | .spec.subnets[]'
}

GetOvnkubeNodePod() {
    typeset kubeconfig="${1:?}"
    typeset nodeName="${2:?}"
    KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes get pods \
        -l app=ovnkube-node \
        --field-selector "spec.nodeName=${nodeName}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

DiagnoseNode() {
    typeset kubeconfig="${1:?}"
    typeset nodeName="${2:?}"
    typeset ovnPod="${3:?}"
    typeset router="${4:?}"

    : "DiagnoseNode: node='${nodeName}' pod='${ovnPod}'"

    typeset chains
    chains="$(KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
        exec "${ovnPod}" -c ovnkube-controller -- \
        nft list table inet ovn-kubernetes 2>/dev/null | grep -E "^\s+chain" || true)"
    : "DiagnoseNode: inet ovn-kubernetes chains: ${chains:-(table not found)}"

    typeset table149
    table149="$(KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
        exec "${ovnPod}" -c ovnkube-controller -- \
        ip route show table 149 2>/dev/null || true)"
    : "DiagnoseNode: table 149: ${table149:-(empty)}"

    typeset lrps
    lrps="$(KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
        exec "${ovnPod}" -c ovnkube-controller -- \
        ovn-nbctl lr-policy-list "${router}" 2>/dev/null | grep reroute || true)"
    : "DiagnoseNode: LRPs (reroute entries): ${lrps:-(none)}"
}

# Fix 1: remove the table 149 default hairpin from a gateway node.
RemoveGatewayHairpin() {
    typeset kubeconfig="${1:?}"
    typeset gwNode="${2:?}"
    typeset ovnPod="${3:?}"

    : "RemoveGatewayHairpin: node='${gwNode}'"
    KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
        exec "${ovnPod}" -c ovnkube-controller -- \
        ip route del default table 149 dev ovn-k8s-mp0 2>/dev/null \
        && : "RemoveGatewayHairpin: DELETED" \
        || : "RemoveGatewayHairpin: not present (ok)"
    typeset table149After
    table149After="$(KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
        exec "${ovnPod}" -c ovnkube-controller -- \
        ip route show table 149 2>/dev/null || true)"
    : "RemoveGatewayHairpin: table 149 after: ${table149After:-(empty)}"
}

# Fix 2 (primary): insert "ip daddr <cidr> return" in all SNAT chains on a node.
# Must use ovnkube-controller — oc debug node nft silently fails (no CAP_NET_ADMIN).
FixNftablesOnNode() {
    typeset kubeconfig="${1:?}"
    typeset nodeName="${2:?}"
    typeset ovnPod="${3:?}"
    typeset remoteSubnetList="${4:?}"

    : "FixNftablesOnNode: node='${nodeName}'"

    typeset -a snatChains=("mgmtport-snat" "ovn-kube-pod-subnet-masq" "ovn-kube-local-gw-masq")
    typeset inlineScript="set +e"
    typeset chain cidr
    for chain in "${snatChains[@]}"; do
        while IFS= read -r cidr; do
            [[ -z "${cidr}" ]] && continue
            inlineScript+="
nft list chain inet ovn-kubernetes ${chain} 2>/dev/null | grep -qF 'ip daddr ${cidr}' \
  || nft insert rule inet ovn-kubernetes ${chain} ip daddr ${cidr} return 2>/dev/null || true"
        done <<< "${remoteSubnetList}"
    done
    for chain in "${snatChains[@]}"; do
        inlineScript+="
echo '=== ${chain} ==='; nft list chain inet ovn-kubernetes ${chain} 2>/dev/null \
  | grep 'return' || echo '(chain not found)'"
    done

    KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes exec "${ovnPod}" \
        -c ovnkube-controller -- bash -c "${inlineScript}" 2>&1 | grep -v '^$' || true
}

# Fix 3 (belt-and-suspenders): populate mgmtport-no-snat-subnets-v4 on gateway nodes.
FixNftablesGatewaySet() {
    typeset kubeconfig="${1:?}"
    typeset gwNode="${2:?}"
    typeset ovnPod="${3:?}"
    typeset nftElements="${4:?}"

    : "FixNftablesGatewaySet: node='${gwNode}'"
    KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes exec "${ovnPod}" \
        -c ovnkube-controller -- \
        nft add element inet ovn-kubernetes mgmtport-no-snat-subnets-v4 \
        "{ ${nftElements} }" 2>&1 | grep -v '^$' || true
    typeset setContent
    setContent="$(KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes exec "${ovnPod}" \
        -c ovnkube-controller -- \
        nft list set inet ovn-kubernetes mgmtport-no-snat-subnets-v4 2>/dev/null || true)"
    : "FixNftablesGatewaySet: set content: ${setContent:-(not found)}"
}

# Fix 4: fix LRP nexthops for the zone owned by this ovnkube-node pod.
# Nexthop determination:
#   gateway node -> its own ovn-k8s-mp0 IP (src IP for xfrm-encrypted packets)
#   worker node  -> transit switch IP from table 150 (routeagent-installed host routes)
# Note: routeagent reconciliation on endpoint change may re-create broken LRPs.
# In stable CI clusters (no endpoint churn) this fix persists for the full test window.
FixLrpNexthops() {
    typeset kubeconfig="${1:?}"
    typeset nodeName="${2:?}"
    typeset ovnPod="${3:?}"
    typeset remoteSubnetList="${4:?}"
    typeset router="${5:?}"

    : "FixLrpNexthops: node='${nodeName}'"

    typeset isGw
    isGw="$(KUBECONFIG="${kubeconfig}" oc get node "${nodeName}" \
        --output=jsonpath='{.metadata.labels.submariner\.io/gateway}' 2>/dev/null || true)"

    typeset nexthop
    if [[ "${isGw}" == "true" ]]; then
        typeset mp0Info
        mp0Info="$(KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
            exec "${ovnPod}" -c ovnkube-controller -- \
            ip addr show ovn-k8s-mp0 2>/dev/null || true)"
        nexthop="$(echo "${mp0Info}" | awk '/inet /{gsub(/\/[0-9]+/,"",$2); print $2; exit}')"
    else
        typeset routeTable150
        routeTable150="$(KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
            exec "${ovnPod}" -c ovnkube-controller -- \
            ip route show table 150 2>/dev/null || true)"
        nexthop="$(echo "${routeTable150}" | awk '/ovn-k8s-mp0/{print $3; exit}')"
    fi

    if [[ -z "${nexthop}" ]]; then
        : "FixLrpNexthops: cannot determine nexthop for '${nodeName}' — skipping"
        return 0
    fi
    : "FixLrpNexthops: nexthop='${nexthop}' isGw='${isGw:-false}'"

    typeset lrPolicies
    lrPolicies="$(KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
        exec "${ovnPod}" -c ovnkube-controller -- \
        ovn-nbctl lr-policy-list "${router}" 2>/dev/null || true)"

    typeset cidr
    while IFS= read -r cidr; do
        [[ -z "${cidr}" ]] && continue
        typeset existingNexthop
        existingNexthop="$(echo "${lrPolicies}" | awk -v c="${cidr}" '$0 ~ c {print $NF}')"
        if [[ "${existingNexthop}" == "${nexthop}" ]]; then
            : "FixLrpNexthops: ${cidr} already correct — skipping"
            continue
        fi
        KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
            exec "${ovnPod}" -c ovnkube-controller -- \
            ovn-nbctl lr-policy-del "${router}" 100 "ip4.dst == ${cidr}" 2>/dev/null || true
        KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
            exec "${ovnPod}" -c ovnkube-controller -- \
            ovn-nbctl lr-policy-add "${router}" 100 "ip4.dst == ${cidr}" \
            reroute "${nexthop}" 2>/dev/null || true
        : "FixLrpNexthops: applied cidr=${cidr} nexthop=${nexthop}"
    done <<< "${remoteSubnetList}"

    typeset verifiedLrps
    verifiedLrps="$(KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
        exec "${ovnPod}" -c ovnkube-controller -- \
        ovn-nbctl lr-policy-list "${router}" 2>/dev/null | grep reroute || true)"
    : "FixLrpNexthops: verified LRPs on ${router}: ${verifiedLrps:-(none)}"
}

ApplyAllFixes() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    : "ApplyAllFixes: spoke='${spokeName}'"

    typeset localClusterID
    localClusterID="$(GetLocalClusterID "${kubeconfig}")"
    if [[ -z "${localClusterID}" ]]; then
        localClusterID="$(KUBECONFIG="${kubeconfig}" oc get endpoints.submariner.io \
            -n submariner-operator \
            -o jsonpath='{range .items[*]}{.spec.cluster_id}{"\n"}{end}' \
            | grep "${spokeName}" | head -1)"
    fi
    if [[ -z "${localClusterID}" ]]; then
        : "ApplyAllFixes: cannot determine localClusterID for '${spokeName}' — skipping"
        return 0
    fi

    typeset remoteSubnetList
    remoteSubnetList="$(GetRemoteSubnets "${kubeconfig}" "${localClusterID}")"
    if [[ -z "${remoteSubnetList}" ]]; then
        : "ApplyAllFixes: no remote subnets for '${spokeName}' — skipping"
        return 0
    fi

    typeset nftElements
    nftElements="$(echo "${remoteSubnetList}" | paste -sd ',' - | sed 's/,/, /g')"
    : "ApplyAllFixes: remote subnets: ${nftElements}"

    typeset -a allNodes
    mapfile -t allNodes < <(KUBECONFIG="${kubeconfig}" oc get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    if [[ ${#allNodes[@]} -eq 0 ]]; then
        : "ApplyAllFixes: no nodes on '${spokeName}' — skipping"
        return 0
    fi

    typeset -a gatewayNodes
    mapfile -t gatewayNodes < <(KUBECONFIG="${kubeconfig}" oc get nodes \
        -l submariner.io/gateway=true \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    # Resolve the cluster router name once; it is consistent within a cluster.
    typeset firstOvnPod router=""
    firstOvnPod="$(GetOvnkubeNodePod "${kubeconfig}" "${allNodes[0]}")"
    if [[ -n "${firstOvnPod}" ]]; then
        typeset lrList
        lrList="$(KUBECONFIG="${kubeconfig}" oc -n openshift-ovn-kubernetes \
            exec "${firstOvnPod}" -c ovnkube-controller -- \
            ovn-nbctl lr-list 2>/dev/null || true)"
        router="$(echo "${lrList}" | awk '/ovn_cluster_router/{gsub(/[()]/,"",$2); print $2; exit}')"
        DiagnoseNode "${kubeconfig}" "${allNodes[0]}" "${firstOvnPod}" "${router:-ovn_cluster_router}"
    fi
    [[ -z "${router}" ]] && router="ovn_cluster_router"

    # Fix 1: remove table 149 hairpin from each gateway node.
    typeset gwNode ovnPod
    for gwNode in "${gatewayNodes[@]+"${gatewayNodes[@]}"}"; do
        ovnPod="$(GetOvnkubeNodePod "${kubeconfig}" "${gwNode}")"
        [[ -z "${ovnPod}" ]] && continue
        RemoveGatewayHairpin "${kubeconfig}" "${gwNode}" "${ovnPod}"
    done

    # Fixes 2 and 4: nftables return rules + LRP nexthops on every node/zone.
    typeset nodeName
    for nodeName in "${allNodes[@]}"; do
        ovnPod="$(GetOvnkubeNodePod "${kubeconfig}" "${nodeName}")"
        if [[ -z "${ovnPod}" ]]; then
            : "ApplyAllFixes: no ovnkube-node pod for '${nodeName}' — skipping"
            continue
        fi
        FixNftablesOnNode "${kubeconfig}" "${nodeName}" "${ovnPod}" "${remoteSubnetList}"
        FixLrpNexthops    "${kubeconfig}" "${nodeName}" "${ovnPod}" "${remoteSubnetList}" "${router}"
    done

    # Fix 3: populate mgmtport-no-snat-subnets-v4 on gateway nodes.
    for gwNode in "${gatewayNodes[@]+"${gatewayNodes[@]}"}"; do
        ovnPod="$(GetOvnkubeNodePod "${kubeconfig}" "${gwNode}")"
        [[ -z "${ovnPod}" ]] && continue
        FixNftablesGatewaySet "${kubeconfig}" "${gwNode}" "${ovnPod}" "${nftElements}"
    done

    sleep "${settleSecs}"
    : "ApplyAllFixes: '${spokeName}' complete"
    true
}

LoadSpokeConfig

typeset -i i
for ((i = 0; i < spokeCount; i++)); do
    ApplyAllFixes "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
done

typeset _tmpKc
for _tmpKc in "${_tmpKubeconfigsToClean[@]+"${_tmpKubeconfigsToClean[@]}"}"; do
    rm -f "${_tmpKc}"
done

true
