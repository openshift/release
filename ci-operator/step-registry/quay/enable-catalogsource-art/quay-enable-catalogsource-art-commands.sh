#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ART publishes Quay FBC images to the public repo
# quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc. Every component image
# referenced inside the FBC is a digest pullspec to registry.redhat.io (production),
# which CI clusters already reach with their default Red Hat pull secret. Therefore
# this step needs NO pull-secret merge, NO ICSP/IDMS mirrors, and NO MCP rollout wait.

# Create custom catalog source pointing at the ART FBC image
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
else #Install Quay operator with the ART FBC image
  resolve_index_image
  echo "Installing Quay from ART FBC image: $MULTISTAGE_PARAM_OVERRIDE_QUAY_INDEX_IMAGE"
  create_catalog_source
  check_catalog_source_status
fi
