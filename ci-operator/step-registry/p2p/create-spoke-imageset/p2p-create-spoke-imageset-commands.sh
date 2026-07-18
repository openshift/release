#!/bin/bash
# Creates a Hive ClusterImageSet on the hub cluster from the nightly release image
# resolved by ci-operator (RELEASE_IMAGE_LATEST), so that acm-interop-p2p-cluster-install
# can provision spoke clusters at a pre-GA OCP version that has no GA ClusterImageSet yet.
#
# The ClusterImageSet is named img<tag>-x86-64, where <tag> is extracted from
# RELEASE_IMAGE_LATEST. This satisfies the img<version>.* prefix search in
# acm-interop-p2p-cluster-install.
#
# Required environment variables (injected by ci-operator):
#   RELEASE_IMAGE_LATEST              – nightly release image URI
#     e.g. registry.ci.openshift.org/ocp/release:4.23.0-0.nightly-2026-07-15-024904
#
# Required environment variables (declared in ref.yaml):
#   ACM_SPOKE_CLUSTER_INITIAL_VERSION – target OCP version, e.g. "4.23"
set -euxo pipefail; shopt -s inherit_errexit

# Extract the image tag (everything after the last colon).
typeset releaseTag="${RELEASE_IMAGE_LATEST##*:}"
typeset imageSetName="img${releaseTag}-x86-64"
typeset spokeVersion="${ACM_SPOKE_CLUSTER_INITIAL_VERSION}"

: "Release image : ${RELEASE_IMAGE_LATEST}"
: "ClusterImageSet: ${imageSetName}"

# Create (or idempotently update) the ClusterImageSet using jq data marshalling
# to avoid injecting shell variables directly into YAML.
jq -cn \
    --arg name  "${imageSetName}" \
    --arg image "${RELEASE_IMAGE_LATEST}" \
    '{
        "apiVersion": "hive.openshift.io/v1",
        "kind":       "ClusterImageSet",
        "metadata":   {"name": $name},
        "spec":       {"releaseImage": $image}
    }' |
yq -p json -o yaml eval . |
oc apply -f -

# Confirm the resource is now accessible.
oc get "clusterimageset/${imageSetName}" 1>/dev/null

# Verify the ClusterImageSet is discoverable using the same prefix search
# performed by acm-interop-p2p-cluster-install.
typeset discoveredName
discoveredName="$(
    oc get clusterimagesets.hive.openshift.io -o json |
    jq -r --arg prefix "img${spokeVersion}." \
        '.items[].metadata.name | select(startswith($prefix))' |
    sort -V |
    tail -n 1
)"

[[ -n "${discoveredName}" ]] || {
    : "ERROR: No ClusterImageSet with prefix 'img${spokeVersion}.' found after creation."
    exit 1
}

: "acm-interop-p2p-cluster-install will use ClusterImageSet: ${discoveredName}"

true
