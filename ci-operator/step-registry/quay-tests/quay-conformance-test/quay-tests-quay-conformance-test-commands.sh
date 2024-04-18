#!/bin/bash

set -euo pipefail
git version
go version

echo "Clone opencontainers distribution-spec Repository..."
cd /tmp && git clone https://github.com/opencontainers/distribution-spec.git && cd distribution-spec/conformance || true

go test -c  && ls || true
go test -c -mod=mod  && ls || true

QUAY_URL=$(cat "$SHARED_DIR"/quayroute)
QUAY_ACCESS_TOKEN=$(cat "$SHARED_DIR"/quay_oauth2_token)
QUAY_OAUTH2_TOEKN="Bearer $QUAY_ACCESS_TOKEN"

# Registry details
OCI_ROOT_URL=$(cat "$SHARED_DIR"/quayroute)
OCI_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
OCI_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)


export OCI_ROOT_URL
export OCI_USERNAME
export OCI_PASSWORD
export OCI_NAMESPACE="myorg/myrepo"
export OCI_CROSSMOUNT_NAMESPACE="myorg/other"

# Which workflows to run
export OCI_TEST_PULL=1
export OCI_TEST_PUSH=1
export OCI_TEST_CONTENT_DISCOVERY=1
export OCI_TEST_CONTENT_MANAGEMENT=1

# Extra settings
export OCI_HIDE_SKIPPED_WORKFLOWS=0
export OCI_DEBUG=0
export OCI_DELETE_MANIFEST_BEFORE_BLOBS=0 # defaults to OCI_DELETE_MANIFEST_BEFORE_BLOBS=1 if not set

echo "parameterssss...."
echo $OCI_ROOT_URL $OCI_USERNAME $OCI_PASSWORD $QUAY_URL $QUAY_ACCESS_TOKEN $QUAY_OAUTH2_TOEKN
./conformance.test

go test -c   && ls  || true
#Set Kubeconfig:
# cd quay-frontend-tests
# skopeo -v
# oc version
# terraform version
# (cp -L $KUBECONFIG /tmp/kubeconfig || true) && export KUBECONFIG_PATH=/tmp/kubeconfig

# #Create Artifact Directory:
# ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
# mkdir -p $ARTIFACT_DIR


# function copyArtifacts {
#     JUNIT_PREFIX="junit_"
#     cp -r ./cypress/results/* $ARTIFACT_DIR
#     for file in "$ARTIFACT_DIR"/*; do
#         if [[ ! "$(basename "$file")" =~ ^"$JUNIT_PREFIX" ]]; then
#             mv "$file" "$ARTIFACT_DIR"/"$JUNIT_PREFIX""$(basename "$file")"
#         fi
#     done
#     cp -r ./cypress/videos/* $ARTIFACT_DIR
# }

# # Install Dependcies defined in packages.json
# yarn install || true

# #Finally Copy the Junit Testing XML files and Screenshots to /tmp/artifacts
# trap copyArtifacts EXIT

# # Cypress Doc https://docs.cypress.io/guides/references/proxy-configuration
# if [ "${QUAY_PROXY}" = "true" ]; then
#     HTTPS_PROXY=$(cat $SHARED_DIR/proxy_public_url)
#     export HTTPS_PROXY
#     HTTP_PROXY=$(cat $SHARED_DIR/proxy_public_url)
#     export HTTP_PROXY
# fi

# #Trigget Quay E2E Testing
# set +x
# quay_route=$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}') || true
# echo "The Quay hostname is $quay_route"
# quay_hostname=${quay_route#*//}
# echo "The Quay hostname is $quay_hostname"
# export CYPRESS_QUAY_ENDPOINT=$quay_hostname
# yarn run smoke || true

