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
        curl -fsSL \
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
    HTTPS_PROXY="$(cat "${SHARED_DIR}/proxy_public_url")"
    export HTTPS_PROXY
    HTTP_PROXY="$(cat "${SHARED_DIR}/proxy_public_url")"
    export HTTP_PROXY
fi

#Trigget Quay E2E Testing
set +x
typeset quayRoute quayHostname
quayRoute="$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}')" || true
quayHostname="${quayRoute#*//}"

if [ "$(printf '%s\n%s' "${quayVersionThreshold}" "${QUAY_VERSION}" | sort -V | head -n1)" = "${quayVersionThreshold}" ]; then
    export CYPRESS_QUAY_ENDPOINT="${quayHostname}"
    export CYPRESS_QUAY_ENDPOINT_PROTOCOL="https"
    export CYPRESS_QUAY_PROJECT="quay-enterprise"
    export CYPRESS_OLD_UI_DISABLED=true
else
    export CYPRESS_QUAY_ENDPOINT="${quayHostname}"
    export CYPRESS_QUAY_VERSION="${QUAY_VERSION}"
fi
set -x

NO_COLOR=1 npm run smoke || true

true
