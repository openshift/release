#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ART FBC images are at quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc (public).
# The bundle/component images inside the FBC reference registry.redhat.io by digest, but
# nightly/pre-release digests are NOT yet published to registry.redhat.io — ART promotes
# them to registry.stage.redhat.io. So OLM bundle unpack of a fresh FBC fails with
# "manifest unknown" when pulling registry.redhat.io/quay/... directly.
#
# To fix this we mirror registry.redhat.io/quay -> registry.stage.redhat.io/quay with an
# ImageDigestMirrorSet and wait for the MachineConfigPool rollout.
#
# registry.stage.redhat.io pull credentials must already be present in the cluster global
# pull secret. Wire the shared `merge-stage-registry-credentials` step BEFORE this step in
# the ci-operator config; it merges the stage credentials (from the openshift-qe vault)
# and waits for its own MCP rollout.

IDMS_NAME="quay-stage-registry"

# Create an ImageDigestMirrorSet redirecting registry.redhat.io/quay digests to
# registry.stage.redhat.io/quay, where ART publishes pre-release Quay images. The GA
# RHEL dependencies (registry.redhat.io/rhel8|rhel9/...) stay on production and are not
# mirrored. The default mirrorSourcePolicy (AllowContactingSource) lets pulls fall back
# to production for any digest already promoted there.
function create_idms () {
  cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${IDMS_NAME}
spec:
  imageDigestMirrors:
  - source: registry.redhat.io/quay
    mirrors:
    - registry.stage.redhat.io/quay
EOF
}

# Wait for the MachineConfigPool rollout triggered by the IDMS.
function wait_mcp_ready () {
    echo "Waiting for MachineConfigPool rollout after IDMS creation..."
    # Give MCO time to start the rollout before waiting for completion. A pool may still
    # report Updated=True from an earlier change, so the initial wait is best-effort.
    oc wait mcp --all --for=condition=Updating=True --timeout=5m || true
    oc wait mcp --all --for=condition=Updated=True --timeout=20m
}

#Create custom catalog source
function create_catalog_source(){
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $QUAY_OPERATOR_SOURCE
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE
  displayName: Quay ART FBC Operator Catalog
  publisher: grpc
EOF

}

#Check catalog source status to Ready
function check_catalog_source_status(){
    local COUNTER=0
    local STATUS=""
    while [ $COUNTER -lt 600 ] #10 min at most
    do
        COUNTER=$((COUNTER + 20))
        echo "waiting ${COUNTER}s"
        sleep 20
        STATUS=$(oc get catalogsources -n openshift-marketplace "$QUAY_OPERATOR_SOURCE" -o=jsonpath="{.status.connectionState.lastObservedState}" || true)
        if [[ $STATUS = "READY" ]]; then
            echo "Create Quay CatalogSource successfully"
            return 0
        fi
    done
    echo "!!! Fail to create Quay CatalogSource"
    return 1
}


# Resolve the ART FBC catalog index image to a pinned digest.
# Precedence:
#   1. An explicit MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE is used verbatim, so a
#      specific ART build can be hard-pinned (ART FBCs are distinguished by digest).
#   2. Otherwise the ART floating tag on QUAY_INDEX_IMAGE_REPO (naming convention
#      <group>__v<ocp_version>__<component_name>, e.g. quay-3.18__v4.22__quay-rhel9-operator)
#      is resolved to an immutable @sha256 digest, so each run tracks the newest FBC
#      build. The art-fbc repo has no ":latest" tag. The repo is public, so no auth is
#      needed for the resolve.
# The resolved reference is written to ${SHARED_DIR}/quay_index_image for traceability.
function resolve_index_image () {
  if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE}" ]]; then
    echo "Using explicitly pinned index image: ${MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE}"
  else
    local ref="${QUAY_INDEX_IMAGE_REPO}:${QUAY_INDEX_IMAGE_TAG}"
    echo "Resolving ART FBC catalog ${ref} to a digest..."
    local digest=""
    # The catalog repo is public, so no auth is needed for the resolve.
    digest=$(oc image info --show-multiarch "${ref}" -o json 2>/dev/null \
      | jq -r 'if type=="array" then .[0].listDigest else .digest end') || true
    if [[ -z "${digest}" || "${digest}" == "null" ]]; then
      echo "oc image info could not resolve ${ref}; trying skopeo..." >&2
      if command -v skopeo >/dev/null 2>&1; then
        digest=$(skopeo inspect --no-tags "docker://${ref}" 2>/dev/null | jq -r '.Digest // ""') || true
      fi
    fi
    if [[ -z "${digest}" || "${digest}" == "null" ]]; then
      echo "!!! Failed to resolve ${ref} to a digest" >&2
      return 1
    fi
    MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE="${QUAY_INDEX_IMAGE_REPO}@${digest}"
    echo "Resolved ${ref} -> ${MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE}"
  fi
  echo "${MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE}" > "${SHARED_DIR}/quay_index_image"
}

#"redhat-operators" is the official catalog source for released builds
if [ "$QUAY_OPERATOR_SOURCE" == "redhat-operators" ]; then
  echo "Installing Quay from released build"
else #Install Quay operator with the ART pre-release FBC image
  resolve_index_image
  echo "Installing Quay from ART FBC image: $MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE"
  create_idms
  wait_mcp_ready
  create_catalog_source
  check_catalog_source_status
fi
