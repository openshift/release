#!/bin/bash

set -euo pipefail

cat /proc/meminfo
cd stage_quay_io_tests/old_ui
skopeo -v
podman -v
(cp -L $KUBECONFIG /tmp/kubeconfig || true) && export KUBECONFIG_PATH=/tmp/kubeconfig

#Create Artifact Directory:
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p $ARTIFACT_DIR


function copyArtifacts {

    if [ -d "./cypress/videos/" ] && [ "$(ls -A "./cypress/videos/")" ]; then
        cp -r ./cypress/videos/* $ARTIFACT_DIR
    fi

    if [ -d  "./cypress/logs/" ] && [ "$(ls -A "./cypress/logs/")" ]; then
        cp -r ./cypress/logs/* $ARTIFACT_DIR
    fi

    JUNIT_PREFIX="junit_"
    if [ -d "./cypress/results/" ] && [ "$(ls -A "./cypress/results/")" ]; then
        cp -r ./cypress/results/* $ARTIFACT_DIR
    fi

    for file in "$ARTIFACT_DIR"/*; do
        if [[ ! "$(basename "$file")" =~ ^"$JUNIT_PREFIX" ]]; then
            mv "$file" "$ARTIFACT_DIR"/"$JUNIT_PREFIX""$(basename "$file")"
        fi
    done

    if [[ -e "./stage_quay_io_testing_report.xml" ]]; then
        cp -r "./stage_quay_io_testing_report.xml" $ARTIFACT_DIR
    fi
}


# Install Dependcies defined in packages.json
yarn install || true
yarn add --dev typescript || true
yarn add --dev cypress-failed-log || true
yarn add --dev @cypress/grep || true

#Finally Copy the Junit Testing XML files and Screenshots to /tmp/artifacts
trap copyArtifacts EXIT

export CYPRESS_NO_COMMAND_LOG=true
NO_COLOR=1 yarn run cypress run -b chrome --reporter cypress-multi-reporters --reporter-options configFile=reporter-config.json


