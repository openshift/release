#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

CopyArtifacts() {
    typeset junitPrefix="junit_"
    cp -r ./cypress/results/* "${ARTIFACT_DIR}/" || true

    for file in "${ARTIFACT_DIR}"/*; do
        if [[ -f "${file}" ]] && [[ ! "$(basename "${file}")" =~ ^"${junitPrefix}" ]]; then
            mv "${file}" "${ARTIFACT_DIR}/${junitPrefix}$(basename "${file}")"
        fi
    done
    cp -r ./cypress/videos/* "${ARTIFACT_DIR}/" || true
    true
}

if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
        "${_fURL[@]}" \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"; trap '
        CopyArtifacts
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--quay-tests__test-quay-e2e__quay-tests-test-quay-e2e.xml
    ' EXIT
else
    trap CopyArtifacts EXIT
fi

typeset quayVersionThreshold="3.16"

if [ "$(printf '%s\n%s' "${quayVersionThreshold}" "${QUAY_VERSION}" | sort -V | head -n1)" = "${quayVersionThreshold}" ]; then
    cd new-ui-tests
else
    #For Quay versions lower than 3.16, use the old UI test suite.
    cd quay-frontend-tests
fi

skopeo -v
oc version
terraform version
(cp -L "${KUBECONFIG}" /tmp/kubeconfig || true) && export KUBECONFIG_PATH=/tmp/kubeconfig

ARTIFACT_DIR="${ARTIFACT_DIR:=/tmp/artifacts}"
mkdir -p "${ARTIFACT_DIR}"

# Install Dependcies defined in packages.json
npm install || true

# Cypress Doc https://docs.cypress.io/guides/references/proxy-configuration
if [ "${QUAY_PROXY}" = "true" ]; then
    ( set +x
        export HTTPS_PROXY="$(tr -d '\n' < "${SHARED_DIR}/proxy_public_url")"
        export HTTP_PROXY="${HTTPS_PROXY}"
    true )
fi

# Trigger Quay E2E testing
( set +x
    quayHostname="$(
        oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}' 2>/dev/null |
        sed -e 's|^[^/]*//||'
    )"
    if [[ -z "${quayHostname}" ]]; then
        echo 'Quay registry endpoint not found.' 1>&2
        exit 1
    fi
    if [ "$(printf '%s\n%s' "${quayVersionThreshold}" "${QUAY_VERSION}" | sort -V | head -n1)" = "${quayVersionThreshold}" ]; then
        export CYPRESS_QUAY_ENDPOINT="${quayHostname}"
        export CYPRESS_QUAY_ENDPOINT_PROTOCOL="https"
        export CYPRESS_QUAY_PROJECT="quay-enterprise"
        export CYPRESS_OLD_UI_DISABLED=true
    else
        export CYPRESS_QUAY_ENDPOINT="${quayHostname}"
        export CYPRESS_QUAY_VERSION="${QUAY_VERSION}"
    fi
true )

NO_COLOR=1 npm run smoke || true

true
