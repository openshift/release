#!/bin/bash
#
# Restore virt-operator replicas on all spoke clusters after CCLM migration tests.
# Counterpart to p2p-cnv-cclm-readiness, which intentionally leaves virt-operator
# at 0 replicas during migrations so it cannot reconcile away the cert mount patch
# (workaround for CNV-89129 / kubevirt#16264).
#
# This step also stops and removes the in-cluster CCLM cert watchdog deployed by
# p2p-cnv-cclm-readiness before restoring virt-operator.  The watchdog must be
# removed first: if left running it would immediately scale virt-operator back to 0
# after this step scales it up.
#
# No-op when CNV_ENABLE_CCLM != "true" (readiness step never ran, nothing to restore).
#
set -euo pipefail; shopt -s inherit_errexit

[[ "${CNV_ENABLE_CCLM}" == "true" ]] || {
    : "CNV_ENABLE_CCLM is not 'true' — nothing to restore"
    true; exit 0
}

readonly cnvNs="openshift-cnv"

# LoadSpokeKubeconfigs — output spoke kubeconfig paths (one per line).
LoadSpokeKubeconfigs() {
    typeset -a kcsArr=()
    typeset -i i
    for ((i = 1; ; i++)); do
        typeset kcPath="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        [[ -f "${kcPath}" ]] || break
        kcsArr+=("${kcPath}")
    done
    if [[ ${#kcsArr[@]} -eq 0 && -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
        kcsArr+=("${SHARED_DIR}/managed-cluster-kubeconfig")
    fi
    ((${#kcsArr[@]} > 0))
    printf '%s\n' "${kcsArr[@]}"
}

# GetSpokeClusterName — return cluster name for 1-based spoke index.
GetSpokeClusterName() {
    typeset -i idx="${1:?}"
    typeset nameFile="${SHARED_DIR}/managed-cluster-name-${idx}"
    if [[ -f "${nameFile}" ]]; then
        cat "${nameFile}"
    else
        printf 'spoke-%d' "${idx}"
    fi
}

# CleanupWatchdogDeployment — remove the CCLM cert watchdog and its RBAC from the spoke.
# Must be called BEFORE restoring virt-operator; otherwise the watchdog would immediately
# scale it back to 0.
CleanupWatchdogDeployment() {
    typeset kubeconfig="${1:?}"
    typeset clusterName="${2:?}"
    : "[${clusterName}] Removing CCLM cert watchdog from ${cnvNs}"

    # Scale watchdog to 0 first so it stops the scale-to-0 loop before we delete it.
    oc --kubeconfig="${kubeconfig}" scale deployment/cclm-watchdog \
        -n "${cnvNs}" --replicas=0 1>/dev/null 2>&1 || true

    typeset -a resourcesToDelete=(
        "deployment/cclm-watchdog"
        "rolebinding/cclm-watchdog"
        "role/cclm-watchdog"
        "serviceaccount/cclm-watchdog"
        "configmap/cclm-watchdog-script"
    )
    typeset res
    for res in "${resourcesToDelete[@]}"; do
        oc --kubeconfig="${kubeconfig}" delete "${res}" \
            -n "${cnvNs}" --ignore-not-found 1>/dev/null || true
    done
    : "[${clusterName}] CCLM cert watchdog removed"
    true
}

typeset -a spokeKubeconfigsArr=()
mapfile -t spokeKubeconfigsArr < <(LoadSpokeKubeconfigs)

typeset -i spokeCount="${#spokeKubeconfigsArr[@]}"
: "=== Restoring virt-operator on ${spokeCount} spoke(s) ==="

typeset -i i
for ((i = 0; i < spokeCount; i++)); do
    typeset kc="${spokeKubeconfigsArr[i]}"
    typeset spkName=""
    spkName="$(GetSpokeClusterName "$((i + 1))")"

    # Stop and remove the watchdog BEFORE scaling virt-operator back up.
    CleanupWatchdogDeployment "${kc}" "${spkName}"

    typeset currentReplicas=""
    currentReplicas="$(oc --kubeconfig="${kc}" get deployment/virt-operator \
        -n "${cnvNs}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"

    if [[ "${currentReplicas}" == "0" ]]; then
        : "[${spkName}] virt-operator is at 0 replicas — restoring to 2"
        oc --kubeconfig="${kc}" scale deployment/virt-operator \
            -n "${cnvNs}" --replicas=2
        oc --kubeconfig="${kc}" rollout status deployment/virt-operator \
            -n "${cnvNs}" --timeout=5m || true
        : "[${spkName}] virt-operator restored"
    else
        : "[${spkName}] virt-operator already at ${currentReplicas} replica(s) — no action needed"
    fi
done

: "virt-operator restore complete on all ${spokeCount} spoke(s)"
true
