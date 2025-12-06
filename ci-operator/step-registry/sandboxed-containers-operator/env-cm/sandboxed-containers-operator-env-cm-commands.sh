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

# The default catalog image doesn't have a "latest" tag associated with, so
# we search in quay.io for the latest built tag.
latest_catsrc_image_tag() {
    local page=1
    while true; do
        local resp
        resp=$(curl -sf "https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/osc-test-fbc/tag/?limit=100&page=$page")

        if ! jq -e '.tags | length > 0' <<< "$resp" >/dev/null; then
            break
        fi

        latest_tag=$(echo "$resp" | \
          jq -r '.tags[]? | select(.name | test("^osc-test-fbc-on-push-.*-build-image-index$")) | "\(.start_ts) \(.name)"' | \
          sort -nr | head -n1 | awk '{print $2}')
        if [ -n "${latest_tag}" ]; then
            echo "${latest_tag}"
            break
        fi

        ((page++))
    done
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
  if [[ "${CATALOG_SOURCE_IMAGE}" = "${default_catsrc_image}:latest" ]]; then
    catsrc_image_tag=$(latest_catsrc_image_tag)
    CATALOG_SOURCE_IMAGE="${default_catsrc_image}:${catsrc_image_tag}"
  fi

  create_catsrc "${CATALOG_SOURCE_NAME}" "${CATALOG_SOURCE_IMAGE}"
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
