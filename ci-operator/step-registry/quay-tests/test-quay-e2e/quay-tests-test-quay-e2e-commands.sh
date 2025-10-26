#!/bin/bash

set -euo pipefail

#Set Kubeconfig:
cd quay-frontend-tests
skopeo -v
oc version
terraform version
(cp -L $KUBECONFIG /tmp/kubeconfig || true) && export KUBECONFIG_PATH=/tmp/kubeconfig

#Create Artifact Directory:
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p $ARTIFACT_DIR

function install_yq_if_not_exists() {
    # Install yq manually if not found in image
    echo "Checking if yq exists"
    cmd_yq="$(yq --version 2>/dev/null || true)"
    if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
    else
        echo "Installing yq"
        mkdir -p /tmp/bin
        export PATH=$PATH:/tmp/bin/
        curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
         -o /tmp/bin/yq && chmod +x /tmp/bin/yq
    fi
}

function mapTestsForComponentReadiness() {
    if [[ $MAP_TESTS == "true" ]]; then
        results_file="${1}"
        echo "Patching Tests Result File: ${results_file}"
        if [ -f "${results_file}" ]; then
            install_yq_if_not_exists
            echo "Mapping Test Suite Name To: Quay-lp-interop"
            yq eval -px -ox -iI0 '.testsuites.testsuite.+@name="Quay-lp-interop"' $results_file
        fi
    fi
}


function copyArtifacts {
    JUNIT_PREFIX="junit_"
    cp -r ./cypress/results/* $ARTIFACT_DIR
    for file in "$ARTIFACT_DIR"/*; do
        if [[ ! "$(basename "$file")" =~ ^"$JUNIT_PREFIX" ]]; then
            $result_file="$ARTIFACT_DIR"/"$JUNIT_PREFIX""$(basename "$file")"
            mv "$file" $result_file

            if [[ $MAP_TESTS == "true" ]]; then
              original_results="${ARTIFACT_DIR}/original_results/"
              mkdir "${original_results}"
              echo "Collecting original results in ${original_results}"

              # Keep a copy of all the original Junit files before modifying them
              cp "${result_file}" "${original_results}/$(basename "$result_file")"

              # Map tests if needed for related use cases
              mapTestsForComponentReadiness "${result_file}"

              # Send junit file to shared dir for Data Router Reporter step
              cp "$result_file" "${SHARED_DIR}/$(basename "$result_file")"
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
export CYPRESS_QUAY_ENDPOINT=$quay_hostname

echo "The quay version is ${QUAY_VERSION}"
export CYPRESS_QUAY_VERSION="${QUAY_VERSION}"

NO_COLOR=1 yarn run smoke || true


