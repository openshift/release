#!/bin/bash
#
# Install OpenShift Virtualization on the ACM spokes through the ACM kubevirt-hyperconverged
# add-on (enabled by the MCH cnv-mtv-integrations component). Labeling a ManagedCluster with
# acm/cnv-operator-install=true makes ACM deploy CNV (OperatorPolicy + HyperConverged with
# decentralizedLiveMigration) and register the cluster as MTV Provider <cluster>-mtv.
# Spoke state is read exclusively through ManagedClusterView.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/f63f1f606b1d76f6ef2a3e78b4ec1ad7362d4fac/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # Disable xtrace: proxy-conf.sh may set HTTP_PROXY with embedded credentials.
    typeset _wasTracing=''
    [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
    set +x
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
    [[ "${_wasTracing}" == "true" ]] && set -x
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]

typeset -r acmOwnerLabel="p2p.interop.openshift.io/owner"
typeset -r acmOwner="p2p-acm-cnv-addon-install"
typeset -i acmViewIntervalSeconds="${P2P_ACM_VIEW_INTERVAL_SECONDS}"
typeset -i acmViewWaitSeconds="${P2P_ACM_VIEW_WAIT_SECONDS}"
typeset -i cnvWaitSeconds=$(( CNV_WAIT_TIMEOUT_MINUTES * 60 ))
typeset -a spokeNamesArr=()

# ── ACM managed-cluster access helpers ────────────────────────────────────────
# Duplicated in every p2p-acm-* / acm-interop-p2p-submariner-addon-* step (each step runs in
# its own container); keep the copies identical.

# AcmObjName — deterministic DNS-safe name for an ACM view/action/work object.
function AcmObjName () {
    typeset prefix="${1:?}"; (($#)) && shift
    printf '%s-%s' "${prefix}" "$(printf '%s|' "$@" | sha256sum | cut -c1-16)"
}

# McvGet — evaluate a jq filter against one object on a managed cluster via ManagedClusterView.
# Args: cluster apiGroup version kind namespace name jqFilter (apiGroup/namespace may be "").
# Prints the filter result; returns 3 when the object does not exist, 1 on view timeout.
# xtrace is off: raw objects (e.g. VM cloud-init) must never reach the CI log.
function McvGet () (
    set +x
    typeset cluster="${1:?}" group="${2}" version="${3:?}" kind="${4:?}" ns="${5}" name="${6:?}"
    typeset filter="${7:?}"
    typeset mcv mcvJson status msg
    typeset -i deadline=$(( SECONDS + acmViewWaitSeconds ))

    mcv="$(AcmObjName "${acmOwner}-v" "${group}" "${kind}" "${ns}" "${name}")"
    jq -cn --arg n "${mcv}" --arg c "${cluster}" --arg lk "${acmOwnerLabel}" --arg lv "${acmOwner}" \
        --arg g "${group}" --arg v "${version}" --arg k "${kind}" --arg ns "${ns}" --arg name "${name}" \
        --argjson iv "${acmViewIntervalSeconds}" '
        {apiVersion: "view.open-cluster-management.io/v1beta1", kind: "ManagedClusterView",
         metadata: {name: $n, namespace: $c, labels: {($lk): $lv}},
         spec: {scope: (({apiGroup: $g, version: $v, kind: $k, namespace: $ns, name: $name}
                         | with_entries(select(.value != ""))) + {updateIntervalSeconds: $iv})}}' |
        oc apply -f - 1>/dev/null || exit 1

    while (( SECONDS < deadline )); do
        mcvJson="$(oc -n "${cluster}" get "managedclusterview/${mcv}" -o json)" || { sleep 5; continue; }
        status="$(jq -r 'first(.status.conditions[]? | select(.type == "Processing") | .status) // ""' <<<"${mcvJson}")"
        if [[ "${status}" == "True" ]]; then
            jq -r ".status.result | ${filter}" <<<"${mcvJson}" || exit 1
            exit 0
        fi
        msg="$(jq -r 'first(.status.conditions[]? | select(.type == "Processing") | .message) // ""' <<<"${mcvJson}")"
        [[ "${status}" == "False" && "${msg}" == *"not found"* ]] && exit 3
        sleep 5
    done
    printf 'ERROR: ManagedClusterView for %s %s/%s on %s not processed within %ds\n' \
        "${kind}" "${ns}" "${name}" "${cluster}" "${acmViewWaitSeconds}" >&2
    exit 1
)

# McvWaitFor — poll McvGet until its jq filter yields "true". Args: timeoutSeconds + McvGet args.
function McvWaitFor () {
    typeset -i timeout="${1:?}"; (($#)) && shift
    typeset -i deadline=$(( SECONDS + timeout )) rc
    typeset out
    while (( SECONDS < deadline )); do
        rc=0
        out="$(McvGet "$@")" || rc=$?
        (( rc == 0 )) && [[ "${out}" == "true" ]] && return 0
        sleep "${acmViewIntervalSeconds}"
    done
    printf 'ERROR: condition %s not met for %s %s/%s on %s after %ds\n' "${7}" "${4}" "${5}" "${6}" "${1}" "${timeout}" >&2
    return 1
}

# McvDrop — delete the view for one object so the next McvGet reads fresh spoke state.
# Args: cluster apiGroup kind namespace name.
function McvDrop () {
    typeset cluster="${1:?}" group="${2}" kind="${3:?}" ns="${4}" name="${5:?}"
    oc -n "${cluster}" delete "managedclusterview/$(AcmObjName "${acmOwner}-v" "${group}" "${kind}" "${ns}" "${name}")" \
        --ignore-not-found 1>/dev/null
}

# AcmCleanup — remove views created by this step (best-effort, EXIT trap).
function AcmCleanup () {
    ( set +x
      oc delete managedclusterview -A -l "${acmOwnerLabel}=${acmOwner}" --ignore-not-found --wait=false \
          1>/dev/null 2>&1 || true
    )
    true
}
trap AcmCleanup EXIT

# ── Step logic ────────────────────────────────────────────────────────────────

# LoadSpokeNames — ACM spoke cluster names written by acm-interop-p2p-cluster-install.
function LoadSpokeNames () {
    typeset -i i count="${ACM_SPOKE_CLUSTER_COUNT}"
    (( count >= 1 ))
    for (( i = 1; i <= count; i++ )); do
        if [[ -s "${SHARED_DIR}/managed-cluster-name-${i}" ]]; then
            spokeNamesArr+=("$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name-${i}")")
        elif (( count == 1 )) && [[ -s "${SHARED_DIR}/managed-cluster-name" ]]; then
            spokeNamesArr+=("$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name")")
        else
            printf 'ERROR: managed-cluster-name-%d missing in SHARED_DIR\n' "${i}" >&2
            return 1
        fi
    done
}

# LabelSpokesForCnv — opt spokes in to the ACM CNV add-on and MTV provider registration.
function LabelSpokesForCnv () {
    typeset cluster
    oc wait "clustermanagementaddon/${CNV_ADDON_NAME}" --for=create --timeout="${cnvWaitSeconds}s"
    for cluster in "${spokeNamesArr[@]}"; do
        oc wait "managedcluster/${cluster}" --for=condition=ManagedClusterConditionAvailable --timeout="${cnvWaitSeconds}s"
        oc label "managedcluster/${cluster}" "${CNV_ADDON_CLUSTER_LABEL}=true" --overwrite
    done
}

# WaitCnvAddon — ACM add-on Available, then HCO Available, CCLM gate, sync controller (via MCV).
function WaitCnvAddon () {
    typeset cluster="${1:?}"; (($#)) && shift

    oc -n "${cluster}" wait "managedclusteraddon/${CNV_ADDON_NAME}" --for=create --timeout="${cnvWaitSeconds}s"
    oc -n "${cluster}" wait "managedclusteraddon/${CNV_ADDON_NAME}" --for=condition=Available \
        --timeout="${cnvWaitSeconds}s"

    McvWaitFor "${cnvWaitSeconds}" "${cluster}" hco.kubevirt.io v1beta1 HyperConverged \
        "${CNV_NAMESPACE}" "${CNV_HCO_NAME}" \
        '[.status.conditions[]? | select(.type == "Available" and .status == "True")] | length > 0'

    McvWaitFor "${cnvWaitSeconds}" "${cluster}" kubevirt.io v1 KubeVirt \
        "${CNV_NAMESPACE}" "${CNV_KUBEVIRT_NAME}" \
        '.spec.configuration.developerConfiguration.featureGates // [] | index("DecentralizedLiveMigration") != null'

    McvWaitFor "${cnvWaitSeconds}" "${cluster}" apps v1 Deployment \
        "${CNV_NAMESPACE}" virt-synchronization-controller \
        '[.status.conditions[]? | select(.type == "Available" and .status == "True")] | length > 0'
}

# RecordCnvVersion — installed CSV/version per spoke; optionally assert the expected major.minor.
function RecordCnvVersion () {
    typeset cluster="${1:?}"; (($#)) && shift
    typeset csv version

    csv="$(McvGet "${cluster}" operators.coreos.com v1alpha1 Subscription \
        "${CNV_NAMESPACE}" "${CNV_SUBSCRIPTION_NAME}" '.status.installedCSV // ""')"
    [[ -n "${csv}" ]]
    version="$(McvGet "${cluster}" operators.coreos.com v1alpha1 ClusterServiceVersion \
        "${CNV_NAMESPACE}" "${csv}" '.spec.version // ""')"
    [[ -n "${version}" ]]
    printf '%s\t%s\t%s\n' "${cluster}" "${csv}" "${version}" >> "${ARTIFACT_DIR}/acm-cnv-addon-versions.tsv"

    if [[ -n "${CNV_EXPECTED_MAJOR_MINOR}" && "${version}" != "${CNV_EXPECTED_MAJOR_MINOR}".* ]]; then
        printf 'ERROR: %s runs CNV %s, expected %s.x (ACM add-on channel %s)\n' \
            "${cluster}" "${version}" "${CNV_EXPECTED_MAJOR_MINOR}" "stable" >&2
        return 1
    fi
}

# DumpDiagnostics — hub-side add-on and policy state (best-effort).
# ARTIFACT_DIR is public: write allowlisted status fields only, never raw objects.
function DumpDiagnostics () {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    typeset diagDir="${ARTIFACT_DIR}/acm-cnv-addon-diagnostics" cluster
    typeset -r condFilter='{name: .metadata.name, conditions: [.status.conditions[]? | {type, status, reason}]}'
    mkdir -p "${diagDir}"
    oc get "clustermanagementaddon/${CNV_ADDON_NAME}" -o json | jq "${condFilter}" \
        > "${diagDir}/cma-status.json" 2>&1 || true
    for cluster in "${spokeNamesArr[@]}"; do
        oc -n "${cluster}" get "managedclusteraddon/${CNV_ADDON_NAME}" -o json | jq "${condFilter}" \
            > "${diagDir}/${cluster}-addon-status.json" 2>&1 || true
        oc -n "${cluster}" get manifestwork -o custom-columns=NAME:.metadata.name,APPLIED:.status.conditions[0].status \
            > "${diagDir}/${cluster}-manifestworks.txt" 2>&1 || true
        McvGet "${cluster}" hco.kubevirt.io v1beta1 HyperConverged "${CNV_NAMESPACE}" "${CNV_HCO_NAME}" \
            '[.status.conditions[]? | {type, status, reason}]' \
            > "${diagDir}/${cluster}-hco-conditions.json" 2>&1 || true
    done
}

LoadSpokeNames
mkdir -p "${ARTIFACT_DIR}"
: > "${ARTIFACT_DIR}/acm-cnv-addon-versions.tsv"

# errexit is ignored inside a subshell used as the left side of ||, so capture $? separately.
typeset -i stepRc=0
set +e
(
    set -e
    typeset cluster
    LabelSpokesForCnv
    for cluster in "${spokeNamesArr[@]}"; do
        WaitCnvAddon "${cluster}"
    done
    for cluster in "${spokeNamesArr[@]}"; do
        RecordCnvVersion "${cluster}"
    done
)
stepRc=$?
set -e

if (( stepRc != 0 )); then
    DumpDiagnostics
    exit "${stepRc}"
fi
true
