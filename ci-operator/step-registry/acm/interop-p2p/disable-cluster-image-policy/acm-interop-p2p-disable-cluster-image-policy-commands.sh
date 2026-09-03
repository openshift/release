#!/bin/bash
#
# Mark ClusterImagePolicy unmanaged on the hub ClusterVersion.
#
# OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY is already on
# ipi-install-install (default true) and this job's steps.env, but the 4.20
# installer does not apply the CVO ignore (cvoignore.go is 4.21+).
# openshift-e2e-test upgrade-paused patches ClusterVersion the same way.
#
set -euxo pipefail; shopt -s inherit_errexit
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ "${OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY}" != "true" ]]; then
    : "OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY is not true; skipping"
    true
    exit 0
fi

typeset kubeconfig="${SHARED_DIR}/kubeconfig"
[ -f "${kubeconfig}" ]

WriteHubImagePolicyFailureDiagnostics() {
    typeset kc="${1:?}"; (($#)) && shift
    oc --kubeconfig="${kc}" get clusterversion version -o jsonpath='{.spec}' \
        > "${ARTIFACT_DIR}/hub-clusterversion-spec-on-failure.json" || true
    true
}

HubImagePolicyFailureCleanup() {
    typeset -i ret=$?
    typeset kc="${1:?}"
    if (( ret != 0 )); then
        WriteHubImagePolicyFailureDiagnostics "${kc}" || true
    fi
}

trap 'HubImagePolicyFailureCleanup "${kubeconfig}"' EXIT

# Append ClusterImagePolicy unmanaged; do not replace existing CVO overrides.
typeset currentOverrides='' newOverrides='' unmanaged=''
currentOverrides="$(oc --kubeconfig="${kubeconfig}" get clusterversion version -o json |
    jq -c '.spec.overrides // []')"
if jq -e '.[] | select(.kind=="ClusterImagePolicy" and .unmanaged==true)' \
        <<<"${currentOverrides}" >/dev/null; then
    : "ClusterImagePolicy already unmanaged on hub"
    true
    exit 0
fi
newOverrides="$(jq -c \
    '. + [{"group":"config.openshift.io","kind":"ClusterImagePolicy","name":"openshift","namespace":"","unmanaged":true}]' \
    <<<"${currentOverrides}")"
oc --kubeconfig="${kubeconfig}" patch clusterversion version --type merge \
    -p "$(jq -cn --argjson overrides "${newOverrides}" '{"spec":{"overrides":$overrides}}')"
unmanaged="$(oc --kubeconfig="${kubeconfig}" get clusterversion version \
    -o jsonpath='{.spec.overrides[?(@.kind=="ClusterImagePolicy")].unmanaged}')"
[[ "${unmanaged}" == *true* ]]
oc --kubeconfig="${kubeconfig}" get clusterversion version -o jsonpath='{.spec.overrides}' \
    > "${ARTIFACT_DIR}/hub-clusterversion-overrides.json"
true
