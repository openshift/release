#!/bin/bash
# Creates a Hive ClusterImageSet on the hub cluster pointing to the latest accepted
# nightly OCP release from the official release controller, so that
# acm-interop-p2p-cluster-install can provision spoke clusters at a pre-GA OCP
# version that has no GA ClusterImageSet yet.
#
# IMPORTANT: RELEASE_IMAGE_LATEST must NOT be used here. It resolves to an
# ephemeral CI build-namespace mirror (registry.build*.ci.openshift.org) that the
# installer treats as an "unknown architecture" override. The bootstrap machines
# spawned by Hive cannot reliably pull all component images from that registry,
# causing the bootkube/cb-bootstrap stage to time out.
#
# Instead, we query the release controller API for the latest accepted nightly at
# registry.ci.openshift.org/ocp/release, which is:
#   - the official CI release image (proper architecture metadata)
#   - accessible from the bootstrap machines via the cluster profile pull secret
#   - a known-good build (passed the release controller acceptance gate)
#
# Required environment variables (declared in ref.yaml):
#   ACM_SPOKE_CLUSTER_INITIAL_VERSION – target OCP version, e.g. "4.23"
set -euxo pipefail; shopt -s inherit_errexit

# Install jq (not present in the cli image by default).
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset spokeVersion="${ACM_SPOKE_CLUSTER_INITIAL_VERSION}"

# Query the release controller for the latest accepted nightly at the official
# registry (registry.ci.openshift.org/ocp/release).
# The release controller API returns {"name": "4.23.0-0.nightly-...", "pullSpec": "..."}
typeset releaseControllerAPI="https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/${spokeVersion}.0-0.nightly/latest"
: "Querying release controller: ${releaseControllerAPI}"

typeset nightlyJson nightlyTag nightlyPullSpec
nightlyJson="$(curl -fsSL "${releaseControllerAPI}")"
nightlyTag="$(   jq -r '.name'     <<< "${nightlyJson}")"
nightlyPullSpec="$(jq -r '.pullSpec' <<< "${nightlyJson}")"

[[ -n "${nightlyTag}"      ]] || { : "ERROR: release controller returned empty nightly name";     exit 1; }
[[ -n "${nightlyPullSpec}" ]] || { : "ERROR: release controller returned empty nightly pullSpec"; exit 1; }

: "Latest accepted nightly: ${nightlyTag}"
: "Pull spec             : ${nightlyPullSpec}"

# Derive the ClusterImageSet name from the nightly tag so it satisfies the
# img<version>.* prefix search in acm-interop-p2p-cluster-install.
# e.g.  4.23.0-0.nightly-2026-07-18-012345  →  img4.23.0-0.nightly-2026-07-18-012345-x86-64
typeset imageSetName="img${nightlyTag}-x86-64"
: "ClusterImageSet name: ${imageSetName}"

# Create (or idempotently update) the ClusterImageSet via jq + oc apply.
# oc apply accepts JSON directly, so no yq conversion is needed.
jq -cn \
    --arg name  "${imageSetName}" \
    --arg image "${nightlyPullSpec}" \
    '{
        "apiVersion": "hive.openshift.io/v1",
        "kind":       "ClusterImageSet",
        "metadata":   {"name": $name},
        "spec":       {"releaseImage": $image}
    }' |
oc apply -f -

# Confirm the resource is accessible.
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
