#!/bin/bash

if test -s "${SHARED_DIR}/proxy-conf.sh"; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

configmap_path="${SHARED_DIR:-$(pwd)}/env-cm.yaml"

if [[ -f "${SHARED_DIR}/disconnected_catalog_source_name" ]]; then
    CATALOG_SOURCE_NAME=$(cat "${SHARED_DIR}/disconnected_catalog_source_name")
    echo "Using disconnected CatalogSource: ${CATALOG_SOURCE_NAME}"

    if [[ -f "${SHARED_DIR}/mirror_registry_url" ]]; then
        MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
        # Keep this in sync with EXTRA_IMAGES_TO_MIRROR: the mirror step copies
        # each image to /extra/<last path segment>, preserving the source tag.
        WORKLOAD_IMAGE="${MIRROR_REGISTRY_HOST}/extra/nginx-unprivileged:alpine"
        echo "Disconnected: using mirrored workload image: ${WORKLOAD_IMAGE}"
    fi
fi

# TODO: still needed? 600 seconds will cause the step timeout?
#echo "Giving a 10min stabilization time for AWS fresh 4.18 cluster before applying kataconfig as workaround for KATA-3451"
#sleep 600

cat <<EOF | tee "${configmap_path}"
apiVersion: v1
kind: ConfigMap
metadata:
  name: osc-config
  namespace: default
data:
  catalogsourcename: "${CATALOG_SOURCE_NAME}"
  operatorVer: ""
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
  credentialsMode: "${CREDENTIALS_MODE:-cco}"
  mustgatherimage: "${MUST_GATHER_IMAGE}"
  workloadImage: "${WORKLOAD_IMAGE}"
  workloadMessage: "${WORKLOAD_MESSAGE}"
  installKataRPM: "false"
  workloadToTest: "${WORKLOAD_TO_TEST}"
EOF

oc create -f "${configmap_path}"
