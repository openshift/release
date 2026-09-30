#!/bin/bash
#
# Enable the ACM MultiClusterHub cnv-mtv-integrations component so ACM owns the MTV lifecycle:
# the mtv-operator add-on installs MTV on the hub (local-cluster) through an OperatorPolicy and
# a ForkliftController with feature_ocp_live_migration enabled; the mtv-integrations controller
# registers labeled managed clusters as MTV Providers and validates Plans with an admission webhook.
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

typeset mchNs="" mchName="" localCluster=""
typeset -i waitTimeoutSeconds=0

# ParseDurationSeconds — convert an oc-style duration (e.g. 2h, 15m, 90s, 1h30m, 1h0m0s) to seconds.
function ParseDurationSeconds () {
    typeset duration="${1:?}"; (($#)) && shift
    if [[ ! "${duration}" =~ ^(([0-9]+)h)?(([0-9]+)m)?(([0-9]+)s)?$ || -z "${duration}" ]]; then
        printf 'ERROR: unrecognised duration %s\n' "${duration}" >&2
        return 1
    fi
    printf '%d' $(( ${BASH_REMATCH[2]:-0} * 3600 + ${BASH_REMATCH[4]:-0} * 60 + ${BASH_REMATCH[6]:-0} ))
}

# ResolveMultiClusterHub — locate the single MultiClusterHub and the hub's self-managed cluster.
function ResolveMultiClusterHub () {
    typeset -a mchRefsArr=()
    mapfile -t mchRefsArr < <(oc get multiclusterhub -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}')
    (( ${#mchRefsArr[@]} == 1 ))
    read -r mchNs mchName <<<"${mchRefsArr[0]}"
    [[ -n "${mchNs}" && -n "${mchName}" ]]

    localCluster="$(oc get managedcluster -l local-cluster=true \
        -o jsonpath='{.items[0].metadata.name}')"
    [[ -n "${localCluster}" ]]
}

# EnableMchComponents — set spec.overrides.components[name].enabled=true for each argument,
# preserving other entries.
function EnableMchComponents () {
    (($#))
    typeset components

    components="$(oc -n "${mchNs}" get "multiclusterhub/${mchName}" -o json |
        jq -c --args '
            reduce $ARGS.positional[] as $c ((.spec.overrides.components // []);
                if any(.[]; .name == $c)
                then map(if .name == $c then .enabled = true else . end)
                else . + [{"name": $c, "enabled": true}]
                end)' "$@")"

    oc -n "${mchNs}" patch "multiclusterhub/${mchName}" --type merge \
        -p "$(jq -cn --argjson comps "${components}" '{"spec": {"overrides": {"components": $comps}}}')"
}

# WaitMchRunning — MultiClusterHub must settle back to Running after the component change.
function WaitMchRunning () {
    oc -n "${mchNs}" wait "multiclusterhub/${mchName}" \
        --for=jsonpath='{.status.phase}'=Running --timeout="${P2P_ACM_MTV_WAIT_TIMEOUT}"
}

# WaitMtvAddonAvailable — the mtv-operator add-on is placed on local-cluster only.
function WaitMtvAddonAvailable () {
    oc wait clustermanagementaddon/mtv-operator --for=create --timeout="${P2P_ACM_MTV_WAIT_TIMEOUT}"
    oc -n "${localCluster}" wait managedclusteraddon/mtv-operator --for=create \
        --timeout="${P2P_ACM_MTV_WAIT_TIMEOUT}"
    oc -n "${localCluster}" wait managedclusteraddon/mtv-operator --for=condition=Available \
        --timeout="${P2P_ACM_MTV_WAIT_TIMEOUT}"
}

# WaitForkliftController — ACM-applied ForkliftController reconciled with CCLM enabled.
function WaitForkliftController () {
    oc wait crd/forkliftcontrollers.forklift.konveyor.io --for=create --timeout="${P2P_ACM_MTV_WAIT_TIMEOUT}"
    oc wait crd/forkliftcontrollers.forklift.konveyor.io --for=condition=Established \
        --timeout="${P2P_ACM_MTV_WAIT_TIMEOUT}"
    oc -n "${MTV_INSTALL_NAMESPACE}" wait "forkliftcontroller/${MTV_FORKLIFT_CONTROLLER_NAME}" \
        --for=create --timeout="${P2P_ACM_MTV_WAIT_TIMEOUT}"
    oc -n "${MTV_INSTALL_NAMESPACE}" wait "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" \
        --for=create --timeout="${P2P_ACM_MTV_WAIT_TIMEOUT}"
    oc -n "${MTV_INSTALL_NAMESPACE}" wait "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" \
        --for=condition=Available --timeout="${P2P_ACM_MTV_WAIT_TIMEOUT}"

    typeset gate
    gate="$(oc -n "${MTV_INSTALL_NAMESPACE}" get "forkliftcontroller/${MTV_FORKLIFT_CONTROLLER_NAME}" \
        -o jsonpath='{.spec.feature_ocp_live_migration}')"
    [[ "${gate}" == "true" ]] || {
        printf 'ERROR: ACM ForkliftController feature_ocp_live_migration=%s (expected true)\n' "${gate}" >&2
        return 1
    }
}

# WaitControllerLiveMigrationEnv — forklift-controller pod template must carry FEATURE_OCP_LIVE_MIGRATION=true.
function WaitControllerLiveMigrationEnv () {
    typeset -i deadline
    typeset envVal=""
    deadline=$(( SECONDS + waitTimeoutSeconds ))

    while (( SECONDS < deadline )); do
        envVal="$(oc -n "${MTV_INSTALL_NAMESPACE}" get "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" \
            -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="FEATURE_OCP_LIVE_MIGRATION")].value}' \
            || true)"
        if [[ "${envVal}" == "true" ]]; then
            oc -n "${MTV_INSTALL_NAMESPACE}" rollout status "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" \
                --timeout="${P2P_ACM_MTV_WAIT_TIMEOUT}"
            return 0
        fi
        sleep 10
    done
    printf 'ERROR: FEATURE_OCP_LIVE_MIGRATION not true on %s\n' "${MTV_FORKLIFT_CONTROLLER_NAME}" >&2
    return 1
}

# WaitPlanWebhookServing — the Plan webhook is failurePolicy=Fail, so Plans cannot be created
# until its service has ready endpoints.
function WaitPlanWebhookServing () {
    typeset -i deadline
    typeset svcNs ready=""
    deadline=$(( SECONDS + waitTimeoutSeconds ))

    oc wait "validatingwebhookconfiguration/${MTV_PLAN_WEBHOOK_CONFIG_NAME}" --for=create \
        --timeout="${P2P_ACM_MTV_WAIT_TIMEOUT}"
    svcNs="$(oc get "validatingwebhookconfiguration/${MTV_PLAN_WEBHOOK_CONFIG_NAME}" \
        -o jsonpath='{.webhooks[0].clientConfig.service.namespace}')"
    [[ -n "${svcNs}" ]]

    while (( SECONDS < deadline )); do
        ready="$(oc -n "${svcNs}" get endpointslice \
            -l "kubernetes.io/service-name=${MTV_PLAN_WEBHOOK_SERVICE_NAME}" -o json |
            jq -r '[.items[].endpoints[]? | select(.conditions.ready == true)] | length' || true)"
        [[ "${ready}" =~ ^[1-9][0-9]*$ ]] && return 0
        sleep 10
    done
    printf 'ERROR: %s has no ready endpoints in %s\n' "${MTV_PLAN_WEBHOOK_SERVICE_NAME}" "${svcNs}" >&2
    return 1
}

# DumpDiagnostics — MCH, add-on, and MTV state to ARTIFACT_DIR (best-effort).
# ARTIFACT_DIR is public: write allowlisted status fields only, never raw objects.
function DumpDiagnostics () {
    [[ -n "${ARTIFACT_DIR}" ]] || return 0
    typeset diagDir="${ARTIFACT_DIR}/acm-mtv-integration-diagnostics"
    mkdir -p "${diagDir}"
    [[ -n "${mchNs}" ]] && oc -n "${mchNs}" get "multiclusterhub/${mchName}" -o json |
        jq '{components: .spec.overrides.components, phase: .status.phase,
             conditions: [.status.conditions[]? | {type, status, reason, message}]}' \
        > "${diagDir}/multiclusterhub-status.json" 2>&1 || true
    oc get clustermanagementaddon > "${diagDir}/clustermanagementaddons.txt" 2>&1 || true
    [[ -n "${localCluster}" ]] && oc -n "${localCluster}" get managedclusteraddon -o json |
        jq '[.items[] | {name: .metadata.name,
             conditions: [.status.conditions[]? | {type, status, reason, message}]}]' \
        > "${diagDir}/local-cluster-addons-status.json" 2>&1 || true
    oc get operatorpolicy -A > "${diagDir}/operatorpolicies.txt" 2>&1 || true
    oc -n "${MTV_INSTALL_NAMESPACE}" get subscription,csv,forkliftcontroller,deploy,pods \
        > "${diagDir}/mtv-install-namespace.txt" 2>&1 || true
}

waitTimeoutSeconds="$(ParseDurationSeconds "${P2P_ACM_MTV_WAIT_TIMEOUT}")"
ResolveMultiClusterHub

# errexit is ignored inside a subshell used as the left side of ||, so capture $? separately.
typeset -i stepRc=0
set +e
(
    set -e
    typeset -a mchComponentsArr=()
    read -r -a mchComponentsArr <<<"${MTV_MCH_COMPONENTS}"
    EnableMchComponents "${mchComponentsArr[@]}"
    WaitMchRunning
    WaitMtvAddonAvailable
    WaitForkliftController
    WaitControllerLiveMigrationEnv
    WaitPlanWebhookServing
)
stepRc=$?
set -e

if [[ -n "${ARTIFACT_DIR}" ]]; then
    oc -n "${MTV_INSTALL_NAMESPACE}" get csv,forkliftcontroller \
        > "${ARTIFACT_DIR}/acm-mtv-integration-status.txt" 2>&1 || true
fi

if (( stepRc != 0 )); then
    DumpDiagnostics
    exit "${stepRc}"
fi
true
