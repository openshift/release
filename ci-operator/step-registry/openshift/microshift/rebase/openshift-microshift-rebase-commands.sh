#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Print context
echo "Environment:"
printenv

# Copy pull secret into place
cp /secrets/ci-pull-secret/.dockercfg "$HOME/.pull-secret.json" || {
    echo "ERROR: Could not copy registry secret file"
}

# Determine pull specs for release images
release_amd64="$(oc get configmap/release-release-images-latest -o yaml \
    | yq '.data."release-images-latest.yaml"' \
    | jq -r '.metadata.name')"
release_arm64="$(oc get configmap/release-release-images-arm64-latest -o yaml \
    | yq '.data."release-images-arm64-latest.yaml"' \
    | jq -r '.metadata.name')"

pullspec_release_amd64="registry.ci.openshift.org/ocp/release:${release_amd64}"
pullspec_release_arm64="registry.ci.openshift.org/ocp-arm64/release-arm64:${release_arm64}"

echo "Pull spec for amd64 release image: ${pullspec_release_amd64}"
echo "Pull spec for arm64 release image: ${pullspec_release_arm64}"

# Call rebase script
./scripts/rebase.sh to "${pullspec_release_amd64}" "${pullspec_release_arm64}"

APP_ID=$(cat /secrets/pr-creds/app_id) \
KEY=/secrets/pr-creds/key.pem \
ORG=openshift \
REPO=microshift \
./scripts/create_pr.py
