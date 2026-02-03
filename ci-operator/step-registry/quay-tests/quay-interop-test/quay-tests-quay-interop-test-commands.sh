#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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


function copyArtifacts {
    JUNIT_PREFIX="junit_"
    cp -r ./cypress/results/* $ARTIFACT_DIR
    for file in "$ARTIFACT_DIR"/*; do
        if [[ ! "$(basename "$file")" =~ ^"$JUNIT_PREFIX" ]]; then
            mv "$file" "$ARTIFACT_DIR"/"$JUNIT_PREFIX""$(basename "$file")"
        fi
    done
    cp -r ./cypress/videos/* $ARTIFACT_DIR
}

# Install Dependcies defined in packages.json
yarn install || true

#Finally Copy the Junit Testing XML files and Screenshots to /tmp/artifacts
trap copyArtifacts EXIT

#Check Quay pod status
set +x
quay_ns=$(oc get quayregistry --all-namespaces | tail -n1 | tr " " "\n" | head -n1)
quay_registry=$(oc get quayregistry -n "$quay_ns" | tail -n1 | tr " " "\n" | head -n1)

for _ in {1..60}; do
    quay_pod_status=$(oc -n "$quay_ns" get pods -l quay-component=quay-app -o go-template='{{$x := ""}}{{range .items}}{{range .status.conditions}}{{if eq .type "Ready"}}{{if or (eq $x "") (eq .status "False")}}{{$x = .status}}{{end}}{{end}}{{end}}{{end}}{{or $x "False"}}')
    if [ "$quay_pod_status" = "True" ]; then
        echo "Quay is running" >&2
        break
    fi
    sleep 10
done

#Trigget Quay E2E Testing
registryEndpoint="$(oc -n "$quay_ns" get quayregistry "$quay_registry" -o jsonpath='{.status.registryEndpoint}')"
registry="${registryEndpoint#https://}"
echo "The Quay hostname is $registryEndpoint"


if [ "$(printf '%s\n%s' "${QUAY_VERSION_THRESHOLD}" "${QUAY_VERSION}" | sort -V | head -n1)" = "${QUAY_VERSION_THRESHOLD}" ]; then
    export CYPRESS_QUAY_ENDPOINT=${registry}
    export CYPRESS_QUAY_PROJECT=${quay_ns}
    export CYPRESS_OLD_UI_DISABLED=true
else
    export CYPRESS_QUAY_ENDPOINT=${registry}
    export CYPRESS_QUAY_VERSION="${QUAY_VERSION}"
fi

NO_COLOR=1 yarn run smoke || true

