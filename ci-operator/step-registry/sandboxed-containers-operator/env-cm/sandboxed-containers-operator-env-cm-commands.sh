#!/bin/bash

configmap_path="${SHARED_DIR:-$(pwd)}/env-cm.yaml"

# TODO: still needed? 600 seconds will cause the step timeout?
#echo "Giving a 10min stabilization time for AWS fresh 4.18 cluster before applying kataconfig as workaround for KATA-3451"
#sleep 600

create_catsrc() {
  local catsrc_name="$1"
  local catsrc_image="$2"
  local catsrc_path="${SHARED_DIR:-$(pwd)}/catsrc_${catsrc_name}.yaml"

  echo "Create a custom catalogsource named ${catsrc_name} for internal builds"

  cat<<-EOF | tee "${catsrc_path}"
  apiVersion: operators.coreos.com/v1alpha1
  kind: CatalogSource
  metadata:
    name: "${catsrc_name}"
    namespace: openshift-marketplace
  spec:
    displayName: QE
    image: "${catsrc_image}"
    publisher: QE
    sourceType: grpc
EOF

  oc apply -f "${catsrc_path}"
}

# The "latest" tag does not convey information about the build time, so
# we search in quay.io for an X.Y.Z-unix_epoch (e.g., 1.11.1-1766149846)
# the first X.Y.Z-unix_epoch tag we find is the newest one because Quay
# returns tags sorted by creation time (newest first).and we return it
# if no tag is found, we return "latest"
#
# Optimization: Quay returns tags sorted by creation time (newest first).
# So the first X.Y.Z-unix_epoch tag we find is the newest one - we can stop immediately.
latest_catsrc_image_tag() {
    local api_url="https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/osc-test-fbc/tag/"
    local page=1
    local max_pages=20 # safety limit, typically exits much earlier

    while [ "$page" -le "$max_pages" ]; do
        local resp
        # Query with onlyActiveTags to skip deleted tags
        resp=$(curl -sf "${api_url}?limit=100&page=${page}&onlyActiveTags=true")

        if [ -z "$resp" ] || ! jq -e '.tags | length > 0' <<< "$resp" >/dev/null 2>&1; then
            break
        fi

        # Find the first matching tag on this page (X.Y.Z-unix_epoch pattern)
        # Since Quay returns newest first, the first match is the latest tag
        local first_match
        first_match=$(echo "$resp" | \
            jq -r '.tags[]? | select(.name | test("^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$")) | .name' | head -1)

        if [ -n "$first_match" ]; then
            echo "$first_match"
            return 0
        fi

        ((page++))
    done

    # Check if we hit max_pages without finding a tag (potential issue)
    if [ "$page" -gt "$max_pages" ]; then
        echo "ERROR: Hit max_pages ($max_pages) limit while searching for tags." >&2
    fi

    # Fallback to :latest if no matching tag found
    echo "WARNING: No X.Y.Z-unix_epoch tag found, using :latest" >&2
    echo "latest"
}

mirror_konflux() {
  echo "Create mirror for konflux images"
  # create the mirror set for the sandboxed-containers-operator and trustee-fbc devel branches
  oc apply -f "https://raw.githubusercontent.com/openshift/sandboxed-containers-operator/refs/heads/devel/.tekton/images-mirror-set.yaml"
  oc apply -f "https://raw.githubusercontent.com/openshift/trustee-fbc/refs/heads/main/.tekton/images-mirror-set.yaml"
}

if [[ "$TEST_RELEASE_TYPE" == "Pre-GA" ]]; then
  mirror_konflux

  default_catsrc_image="quay.io/redhat-user-workloads/ose-osc-tenant/osc-test-fbc"
  # Only resolve the tag if it's :latest
  # Other tags (specific versions like 1.11.1-1766149846 or SHAs) are passed through unchanged
  if [[ "${CATALOG_SOURCE_IMAGE}" = "${default_catsrc_image}:latest" ]]; then
    catsrc_image_tag=$(latest_catsrc_image_tag)
    CATALOG_SOURCE_IMAGE="${default_catsrc_image}:${catsrc_image_tag}"
    echo "Resolved :latest to tag: ${catsrc_image_tag}"
  else
    echo "Using provided catalog image: ${CATALOG_SOURCE_IMAGE}"
  fi

  create_catsrc "${CATALOG_SOURCE_NAME}" "${CATALOG_SOURCE_IMAGE}"

  # Save resolved CATALOG_SOURCE_IMAGE for subsequent steps
  echo "CATALOG_SOURCE_IMAGE=${CATALOG_SOURCE_IMAGE}" > "${SHARED_DIR}/catalog-source-image.env"
  echo "Saved resolved CATALOG_SOURCE_IMAGE to ${SHARED_DIR}/catalog-source-image.env"
else
  if [[ -n "$CATALOG_SOURCE_IMAGE" ]]; then
    echo "CATALOG_SOURCE_IMAGE can only be used when TEST_RELEASE_TYPE==Pre-GA ($CATALOG_SOURCE_IMAGE)"
    exit 1
  fi
fi

cat <<EOF | tee "${configmap_path}"
apiVersion: v1
kind: ConfigMap
metadata:
  name: osc-config
  namespace: default
data:
  catalogsourcename: "${CATALOG_SOURCE_NAME}"
  operatorVer: "${EXPECTED_OPERATOR_VERSION}"
  channel: "${OPERATOR_UPDATE_CHANNEL}"
  redirectNeeded: "false"
  exists: "true"
  labelSingleNode: "false"
  eligibility: "false"
  eligibleSingleNode: "false"
  enableGPU: "${ENABLEGPU}"
  podvmImageUrl: "${PODVM_IMAGE_URL}"
  runtimeClassName: "${RUNTIMECLASS}"
  trusteeUrl: "${TRUSTEE_URL}"
  INITDATA: "${INITDATA}"
  enablePeerPods: "${ENABLEPEERPODS}"
  mustgatherimage: "${MUST_GATHER_IMAGE}"
  workloadImage: "${WORKLOAD_IMAGE}"
  installKataRPM: "${INSTALL_KATA_RPM}"
  workloadToTest: "${WORKLOAD_TO_TEST}"
EOF

oc create -f "${configmap_path}"
