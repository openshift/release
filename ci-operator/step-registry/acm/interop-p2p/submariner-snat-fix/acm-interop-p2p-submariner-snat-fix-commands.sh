#!/bin/bash
#
# Submariner SNAT Workaround for OVN-Kubernetes IC mode
#
# Ref: ACM-22805, ACM-24786, ACM-36927
# Ref: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.13/html/release_notes/acm-release-notes#source-ip-ocp-ovnk
#
# Root cause: OVN-K nftables mgmtport-snat chain rewrites the source IP of
# cross-cluster traffic, breaking return routing.
#
# Workaround (per official ACM docs):
#   1. Create submariner-global ConfigMap with enable-snat-handler=true
#      Tells Submariner's route agent to install nftables rules that exempt
#      cross-cluster traffic from OVN-K's SNAT.
#   2. Restart submariner-routeagent DaemonSet — only reads ConfigMap at startup.
#   3. Wait for rollout and settle.
#
# NOTE: ovnkube-node is intentionally NOT restarted. The official workaround
# (ACM 2.13 docs) only requires route-agent restart. Restarting ovnkube-node
# after route-agent re-programs OVN flows and can overwrite the nftables
# exemption installed by the route-agent, negating the fix on OCP 4.22+.
#
# Applied to every spoke cluster. Idempotent: safe to re-run.
#

set -euxo pipefail; shopt -s inherit_errexit

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

# ── ApplySnatFix — apply SNAT workaround to one spoke ────────────────────────
ApplySnatFix() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    : "ApplySnatFix: spoke='${spokeName}'"

    # Step 1: submariner-global ConfigMap — idempotent via dry-run+apply
    KUBECONFIG="${kubeconfig}" oc create configmap submariner-global \
        -n submariner-operator \
        --from-literal=enable-snat-handler=true \
        --dry-run=client -o yaml --save-config | \
    KUBECONFIG="${kubeconfig}" oc apply -f -

    # Step 2: restart routeagent — picks up enable-snat-handler at startup
    KUBECONFIG="${kubeconfig}" oc delete pod \
        -n submariner-operator \
        -l app=submariner-routeagent \
        --wait=false

    # Step 3: wait for routeagent rollout; non-fatal timeout so job continues
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-routeagent \
        -n submariner-operator \
        --timeout=5m || \
        : "routeagent rollout on '${spokeName}': timed out — continuing"

    # Step 4: settle — allow nftables rules to propagate across all nodes
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
