#!/bin/bash

set -euo pipefail

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

#Create Artifact Directory:
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p $ARTIFACT_DIR
original_results="${ARTIFACT_DIR}/original_results/"
mkdir "${original_results}" || true

function install_yq() {
    # Install yq manually if not found in image
    echo "Installing yq"
    mkdir -p /tmp/bin
    export PATH=$PATH:/tmp/bin/
    curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
     -o /tmp/bin/yq && chmod +x /tmp/bin/yq

    # Verify installation
    cmd_yq="$(/tmp/bin/yq --version 2>/dev/null || true)"
    if [ -n "$cmd_yq" ]; then
      echo "yq version: $cmd_yq"
    else
      # Skip test mapping since yq isn't available
      export MAP_TESTS="false"
    fi
}

function mapTestsForComponentReadiness() {
    if [[ $MAP_TESTS == "true" ]]; then
        results_file="${1}"
        echo "Patching Tests Result File: ${results_file}"
        if [ -f "${results_file}" ]; then
            echo "Mapping Test Suite Name To: Quay-lp-interop"
            /tmp/bin/yq eval -px -ox -iI0 '.testsuites.testsuite[]."+@name"="Quay-lp-interop"' $results_file || echo "Warning: yq failed for ${results_file}, debug manually" >&2
        fi
    fi
}


function copyArtifacts {
    JUNIT_PREFIX="junit_"
    cp -r ./cypress/results/* $ARTIFACT_DIR

    if [[ $MAP_TESTS == "true" ]]; then
      # If needed, install yq before loop
      install_yq
    fi

    for file in "$ARTIFACT_DIR"/*; do
        if [[ ! "$(basename "$file")" =~ ^"$JUNIT_PREFIX" ]]; then
            result_file="$ARTIFACT_DIR"/"$JUNIT_PREFIX""$(basename "$file")"
            mv "$file" $result_file

            if [[ $MAP_TESTS == "true" ]]; then
              echo "Collecting original results in ${original_results}"
              # Keep a copy of all the original Junit files before modifying them
              cp -r $result_file "${original_results}" || echo "Warning: couldn't copy original file ${results_file}" >&2

              # Map tests if needed for related use cases
              mapTestsForComponentReadiness "${result_file}"

              # Send junit file to shared dir for Data Router Reporter step
              cp -r $result_file $SHARED_DIR || echo "Warning: couldn't send result file to SHARED_DIR" >&2
            fi
        fi
    done
    cp -r ./cypress/videos/* $ARTIFACT_DIR
}

# Install Dependcies defined in packages.json
yarn install || true

#Finally Copy the Junit Testing XML files and Screenshots to /tmp/artifacts
trap copyArtifacts EXIT

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

NO_COLOR=1 yarn run smoke || true
