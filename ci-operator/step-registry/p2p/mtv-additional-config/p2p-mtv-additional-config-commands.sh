#!/bin/bash
#
# Configure MTV on the ACM hub after install-operators deploys mtv-operator:
# ForkliftController with CCLM feature gate, deployment readiness, verification.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

if [[ -n "${SHARED_DIR}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

[[ -n "${KUBECONFIG}" ]]
[[ -r "${KUBECONFIG}" ]]


# ParseOcWaitDurationSeconds — convert oc wait duration (e.g. 2h, 15m) to seconds.
ParseOcWaitDurationSeconds() {
    typeset duration="${1:?}"
    if [[ "${duration}" =~ ^([0-9]+)h$ ]]; then
        printf '%s' $(( BASH_REMATCH[1] * 3600 ))
    elif [[ "${duration}" =~ ^([0-9]+)m$ ]]; then
        printf '%s' $(( BASH_REMATCH[1] * 60 ))
    elif [[ "${duration}" =~ ^([0-9]+)s$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        : "Unrecognised duration format '${duration}'; defaulting to 600s"
        printf '%s' 600
    fi
}

# WaitControllerLiveMigrationEnv — forklift-controller must expose FEATURE_OCP_LIVE_MIGRATION=true.
WaitControllerLiveMigrationEnv() {
    typeset -i envWaitSeconds
    typeset -i pollInt=5
    typeset envVal

    envWaitSeconds="$(ParseOcWaitDurationSeconds "${MTV_CONTROLLER_ENV_WAIT_TIMEOUT}")"

    (
        SECONDS=0
        while (( SECONDS < envWaitSeconds )); do
            envVal="$(oc get "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" -n "${MTV_INSTALL_NAMESPACE}" \
                -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="FEATURE_OCP_LIVE_MIGRATION")].value}' \
                || true)"
            if [[ "${envVal}" == "true" ]]; then
                oc rollout status "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" \
                    -n "${MTV_INSTALL_NAMESPACE}" \
                    --timeout="${MTV_CONTROLLER_WAIT_TIMEOUT}" 1>/dev/null
                exit 0
            fi
            : "Waiting for FEATURE_OCP_LIVE_MIGRATION=true on ${MTV_FORKLIFT_CONTROLLER_NAME} (${SECONDS}/${envWaitSeconds}s)"
            sleep "${pollInt}"
        done

        oc get "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" -n "${MTV_INSTALL_NAMESPACE}" \
            -o jsonpath='{range .spec.template.spec.containers[*].env[*]}{.name}{"="}{.value}{"\n"}{end}' \
            1>&2 || true
        : "FEATURE_OCP_LIVE_MIGRATION env not set to true after ${envWaitSeconds}s" >&2
        exit 1
    )
    true
}

{
    oc create -f - --dry-run=client -o json --save-config |
    jq -c \
        --arg name "${MTV_FORKLIFT_CONTROLLER_NAME}" \
        --arg ns   "${MTV_INSTALL_NAMESPACE}" \
        --arg olm  "${MTV_OLM_MANAGED}" \
        --arg ui   "${MTV_FEATURE_UI_PLUGIN}" \
        --arg val  "${MTV_FEATURE_VALIDATION}" \
        --arg vol  "${MTV_FEATURE_VOLUME_POPULATOR}" \
        --arg lm   "${MTV_FEATURE_OCP_LIVE_MIGRATION}" \
        '
        .metadata.name = $name |
        .metadata.namespace = $ns |
        .spec.olm_managed = ($olm == "true") |
        .spec.feature_ui_plugin = $ui |
        .spec.feature_validation = $val |
        .spec.feature_volume_populator = $vol |
        .spec.feature_ocp_live_migration = $lm
        '
} 0<<'ocEOF' | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: ForkliftController
metadata:
  name: placeholder
  namespace: placeholder
spec:
  olm_managed: true
  feature_ui_plugin: "true"
  feature_validation: "true"
  feature_volume_populator: "true"
  feature_ocp_live_migration: "true"
ocEOF

# ForkliftController reconcile creates deployment asynchronously; wait for create then Available.
if ! oc wait --for=create "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" \
        -n "${MTV_INSTALL_NAMESPACE}" \
        --timeout="${MTV_CONTROLLER_CREATE_WAIT_TIMEOUT}"; then
    oc -n "${MTV_INSTALL_NAMESPACE}" get forkliftcontroller,deploy,pods -o wide || true
    exit 1
fi

if ! oc wait "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" \
        -n "${MTV_INSTALL_NAMESPACE}" \
        --for=condition=Available \
        --timeout="${MTV_CONTROLLER_WAIT_TIMEOUT}"; then
    oc -n "${MTV_INSTALL_NAMESPACE}" get deploy,pods -o wide || true
    exit 1
fi

typeset liveMigrationEnabled
liveMigrationEnabled="$(oc get "forkliftcontroller/${MTV_FORKLIFT_CONTROLLER_NAME}" \
    -n "${MTV_INSTALL_NAMESPACE}" \
    -o jsonpath='{.spec.feature_ocp_live_migration}')"
[[ "${liveMigrationEnabled}" == "true" ]]

WaitControllerLiveMigrationEnv

true
