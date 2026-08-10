#!/bin/bash
# Submariner SNAT workaround for OVN-K IC mode on OCP 4.21+.
# Ref: ACM-22805, CORENET-7418, OCPSTRAT-940; upstream fix: ovn-kubernetes PR #6030
#
# Root cause: two independent POSTROUTING basechains in "inet ovn-kubernetes" both
# SNAT cross-cluster traffic, rewriting the source IP and breaking TCP:
#   mgmtport-snat (priority 100)       — masquerades traffic via ovn-k8s-mp0
#   ovn-kube-local-gw-masq (priority 101) — masquerades ALL pod-subnet traffic
# A "return" in chain 1 does NOT stop chain 2 (independent hooks), so the
# ConfigMap / enable-snat-handler fix only repaired ICMP, never TCP.
#
# Fix: prepend "ip daddr <remote-cidr> return" in both chains on every node.
# Also populates mgmtport-no-snat-subnets-v4 set on gateway nodes (belt-and-suspenders).
# Does NOT restart routeagent — that would re-trigger NAT discovery and break IPsec.
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

# Match this spoke's cluster_id via its gateway node's short hostname.
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

# One subnet per line from all remote (non-local) Endpoint CRs.
GetRemoteSubnets() {
    typeset kubeconfig="${1:?}"
    typeset localClusterID="${2:?}"
    KUBECONFIG="${kubeconfig}" oc get endpoints.submariner.io \
        -n submariner-operator -o json \
    | jq -r --arg local "${localClusterID}" \
        '.items[] | select(.spec.cluster_id != $local) | .spec.subnets[]'
}

# Belt-and-suspenders: populate mgmtport-no-snat-subnets-v4 set on gateway nodes.
InjectNftablesOnGateway() {
    typeset kubeconfig="${1:?}"
    typeset gatewayNode="${2:?}"
    typeset nftElements="${3:?}"  # comma-separated CIDRs

    : "InjectNftablesOnGateway: node='${gatewayNode}'"
    KUBECONFIG="${kubeconfig}" oc debug "node/${gatewayNode}" \
        --quiet --to-namespace=default -- chroot /host \
        nft add element inet ovn-kubernetes mgmtport-no-snat-subnets-v4 \
        "{ ${nftElements} }" 2>&1 | grep -v '^$' || true
    KUBECONFIG="${kubeconfig}" oc debug "node/${gatewayNode}" \
        --quiet --to-namespace=default -- chroot /host \
        nft list set inet ovn-kubernetes mgmtport-no-snat-subnets-v4 \
        2>/dev/null || true
}

# Diagnostic: list all chains in "inet ovn-kubernetes" and dump the two masquerade chains.
# Run once per spoke (on the first node) to confirm chain topology before the fix is applied.
DiagnoseNftablesOnNode() {
    typeset kubeconfig="${1:?}"
    typeset nodeName="${2:?}"

    : "DiagnoseNftablesOnNode: node='${nodeName}'"
    KUBECONFIG="${kubeconfig}" oc debug "node/${nodeName}" \
        --quiet --to-namespace=default -- chroot /host bash -c '
set +e
echo "=== inet ovn-kubernetes chains ==="
nft list table inet ovn-kubernetes 2>/dev/null \
    | grep -E "^\s+chain " || echo "(table not found)"
for chain in ovn-kube-local-gw-masq ovn-kube-pod-subnet-masq; do
    echo "=== chain: ${chain} ==="
    nft list chain inet ovn-kubernetes ${chain} 2>/dev/null \
        || echo "(chain not found)"
done
' 2>&1 | grep -v '^$' || true
}

# Primary fix: prepend "ip daddr <cidr> return" in both SNAT chains on any node.
# Both chains are independent hooks — must patch both to fully exempt cross-cluster traffic.
# Absent chains are silently skipped; single oc debug node call (inject + verify).
InjectNftablesReturnRulesOnNode() {
    typeset kubeconfig="${1:?}"
    typeset nodeName="${2:?}"
    typeset remoteSubnetList="${3:?}"  # newline-separated CIDRs

    : "InjectNftablesReturnRulesOnNode: node='${nodeName}'"

    # ovn-kube-pod-subnet-masq: sub-chain on some builds; ovn-kube-local-gw-masq: base chain on OCP 4.22+.
    # Patch all three; absent chains are silently skipped (2>/dev/null || true).
    typeset -a snatChains=("mgmtport-snat" "ovn-kube-pod-subnet-masq" "ovn-kube-local-gw-masq")
    typeset inlineScript="set -euo pipefail"
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
nft list chain inet ovn-kubernetes ${chain} 2>/dev/null | grep 'return' || true"
    done

    KUBECONFIG="${kubeconfig}" oc debug "node/${nodeName}" \
        --quiet --to-namespace=default -- chroot /host \
        bash -c "${inlineScript}" 2>&1 | grep -v '^$' || true
}

ApplySnatFix() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    : "ApplySnatFix: spoke='${spokeName}'"

    typeset localClusterID
    localClusterID="$(GetLocalClusterID "${kubeconfig}")"
    if [[ -z "${localClusterID}" ]]; then
        localClusterID="$(KUBECONFIG="${kubeconfig}" oc get endpoints.submariner.io \
            -n submariner-operator \
            -o jsonpath='{range .items[*]}{.spec.cluster_id}{"\n"}{end}' \
            | grep "${spokeName}" | head -1)"
    fi
    if [[ -z "${localClusterID}" ]]; then
        : "ApplySnatFix: could not determine localClusterID for '${spokeName}' — skipping"
        return 0
    fi

    typeset remoteSubnetList
    remoteSubnetList="$(GetRemoteSubnets "${kubeconfig}" "${localClusterID}")"
    if [[ -z "${remoteSubnetList}" ]]; then
        : "ApplySnatFix: no remote subnets found for '${spokeName}' — skipping"
        return 0
    fi

    typeset nftElements
    nftElements="$(echo "${remoteSubnetList}" | paste -sd ',' - | sed 's/,/, /g')"
    : "ApplySnatFix: remote subnets: ${nftElements}"

    typeset -a allNodes
    mapfile -t allNodes < <(KUBECONFIG="${kubeconfig}" oc get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    if [[ ${#allNodes[@]} -eq 0 ]]; then
        : "ApplySnatFix: no nodes found on '${spokeName}' — skipping"
        return 0
    fi

    DiagnoseNftablesOnNode "${kubeconfig}" "${allNodes[0]}"

    typeset nodeName
    for nodeName in "${allNodes[@]}"; do
        InjectNftablesReturnRulesOnNode "${kubeconfig}" "${nodeName}" "${remoteSubnetList}"
    done

    typeset -a gatewayNodes
    mapfile -t gatewayNodes < <(KUBECONFIG="${kubeconfig}" oc get nodes \
        -l submariner.io/gateway=true \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    typeset gwNode
    for gwNode in "${gatewayNodes[@]+"${gatewayNodes[@]}"}"; do
        InjectNftablesOnGateway "${kubeconfig}" "${gwNode}" "${nftElements}"
    done

    sleep "${settleSecs}"
    : "ApplySnatFix: '${spokeName}' complete"
    true
}

LoadSpokeConfig

typeset -i i
for ((i = 0; i < spokeCount; i++)); do
    ApplySnatFix "${spokeKubeconfigsArr[i]}" "${spokeNamesArr[i]}"
done

typeset _tmpKc
for _tmpKc in "${_tmpKubeconfigsToClean[@]+"${_tmpKubeconfigsToClean[@]}"}"; do
    rm -f "${_tmpKc}"
done

true
