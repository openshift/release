#!/bin/bash
# Creates a Hive ClusterImageSet on the hub cluster pointing to the CI build-namespace
# nightly image (RELEASE_IMAGE_LATEST) so that acm-interop-p2p-cluster-install can
# provision spoke clusters at a pre-GA OCP version that has no GA ClusterImageSet yet.
#
# Why RELEASE_IMAGE_LATEST instead of the release controller API:
#   RELEASE_IMAGE_LATEST resolves to the same CI build-namespace mirror used by the hub
#   cluster bootstrap (registry.build*.ci.openshift.org/ci-op-<id>/release@sha256:...).
#   This registry is publicly reachable but requires CI credentials.  When the Hive spoke
#   pull secret is created from CLUSTER_PROFILE_DIR/pull-secret (ACM_SPOKE_PULL_SECRET_FILE
#   set to "pull-secret" in the workflow env), the spoke bootstrap EC2 machines carry those
#   CI credentials and can pull all component images from the same fast CI mirror, matching
#   the hub's bootstrap performance and avoiding quay.io rate limits or latency that could
#   push the 45-minute Hive bootstrap timeout.
#
#   The release controller API alternative was tested and found to point to
#   registry.ci.openshift.org/ocp/release, which lacks some of the component images
#   pre-mirrored into the CI build namespace, reintroducing the slow-pull failure mode.
#
# Required environment variables:
#   RELEASE_IMAGE_LATEST               – provided automatically by ci-operator when
#                                        releases: latest: ... is set in the CI config.
#   ACM_SPOKE_CLUSTER_INITIAL_VERSION  – e.g. "4.23"; used to name the ClusterImageSet
#                                        with the img<version>.* prefix pattern that
#                                        acm-interop-p2p-cluster-install expects.
set -euxo pipefail; shopt -s inherit_errexit

# Install jq (not present in the cli image by default).
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset spokeVersion="${ACM_SPOKE_CLUSTER_INITIAL_VERSION}"
typeset releaseImage="${RELEASE_IMAGE_LATEST}"

[[ -n "${spokeVersion}"   ]] || { : "ERROR: ACM_SPOKE_CLUSTER_INITIAL_VERSION is empty"; exit 1; }
[[ -n "${releaseImage}"   ]] || { : "ERROR: RELEASE_IMAGE_LATEST is empty";               exit 1; }

: "Spoke OCP version : ${spokeVersion}"
: "Release image     : ${releaseImage}"

# Name the ClusterImageSet so it satisfies the img<version>.* prefix search performed
# by acm-interop-p2p-cluster-install.  We append "-ci-nightly" to distinguish it from
# GA ClusterImageSets (e.g. img4.22.0-x86-64) and "-x86-64" to match the standard suffix
# convention.
typeset imageSetName="img${spokeVersion}.0-ci-nightly-x86-64"
: "ClusterImageSet name: ${imageSetName}"

# Create (or idempotently update) the ClusterImageSet via jq + oc apply.
# oc apply accepts JSON directly; no yq conversion needed.
jq -cn \
    --arg name  "${imageSetName}" \
    --arg image "${releaseImage}" \
    '{
        "apiVersion": "hive.openshift.io/v1",
        "kind":       "ClusterImageSet",
        "metadata":   {"name": $name},
        "spec":       {"releaseImage": $image}
    }' | oc apply -f -

# Confirm the resource is accessible.
oc get "clusterimageset/${imageSetName}" 1>/dev/null

# Verify the ClusterImageSet is discoverable using the same prefix search performed by
# acm-interop-p2p-cluster-install.
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
