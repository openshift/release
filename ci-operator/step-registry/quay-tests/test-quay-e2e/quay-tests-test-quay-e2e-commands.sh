#!/bin/bash

set -euo pipefail

#Create Artifact Directory
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p $ARTIFACT_DIR

function copyArtifacts {
    typeset junitPrefix="junit_"
    cp -r ./cypress/results/* "$ARTIFACT_DIR" || true

    for file in "$ARTIFACT_DIR"/*; do
        if [[ ! "$(basename "$file")" =~ ^"$junitPrefix" ]]; then
            result_file="$ARTIFACT_DIR"/"$junitPrefix""$(basename "$file")"
            mv "$file" "$result_file"
        fi
    done
    cp -r ./cypress/videos/* "$ARTIFACT_DIR" || true
}

if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
        "${_fURL[@]}" \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"; trap '
        copyArtifacts
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--quay-tests__test-quay-e2e__quay-tests-test-quay-e2e.xml
    ' EXIT
else
    trap copyArtifacts EXIT
fi

#Set Kubeconfig:
echo "Quay version is ${QUAY_VERSION}"
QUAY_VERSION_THRESHOLD="3.16"
if [ "$(printf '%s\n%s' "${QUAY_VERSION_THRESHOLD}" "${QUAY_VERSION}" | sort -V | head -n1)" = "${QUAY_VERSION_THRESHOLD}" ]; then
    #For Quay versions equal to or higher than 3.16, use the new UI test suite.
    cd new-ui-tests
else
    #For Quay versions lower than 3.16, use the old UI test suite.
    cd quay-frontend-tests
fi
echo "Current testing directory is $(pwd)"

skopeo -v
oc version
terraform version
(cp -L $KUBECONFIG /tmp/kubeconfig || true) && export KUBECONFIG_PATH=/tmp/kubeconfig

# Install Dependcies defined in packages.json
npm install || true

# Cypress Doc https://docs.cypress.io/guides/references/proxy-configuration
if [ "${QUAY_PROXY}" = "true" ]; then
    HTTPS_PROXY=$(cat $SHARED_DIR/proxy_public_url)
    export HTTPS_PROXY
    HTTP_PROXY=$(cat $SHARED_DIR/proxy_public_url)
    export HTTP_PROXY
fi

#Trigget Quay E2E Testing
set +x
quay_route=$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}') || true
echo "The Quay hostname is $quay_route"
quay_hostname=${quay_route#*//}
echo "The Quay hostname is $quay_hostname"

if [ "$(printf '%s\n%s' "${QUAY_VERSION_THRESHOLD}" "${QUAY_VERSION}" | sort -V | head -n1)" = "${QUAY_VERSION_THRESHOLD}" ]; then
    export CYPRESS_QUAY_ENDPOINT=${quay_hostname}
    export CYPRESS_QUAY_ENDPOINT_PROTOCOL="https"
    export CYPRESS_QUAY_PROJECT="quay-enterprise"
    export CYPRESS_OLD_UI_DISABLED=true
else
    export CYPRESS_QUAY_ENDPOINT=${quay_hostname}
    export CYPRESS_QUAY_VERSION="${QUAY_VERSION}"
fi

NO_COLOR=1 node_modules/.bin/cypress run -b electron --reporter cypress-multi-reporters --reporter-options configFile=reporter-config.json --env grepTags='smoke',grepFilterSpecs=true || true

echo "Sleeping 8h for debugging..."
sleep 8h
