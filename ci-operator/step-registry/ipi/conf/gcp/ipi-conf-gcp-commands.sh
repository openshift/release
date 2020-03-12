#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CLUSTER_TYPE}" != gcp ]]; then
    echo "no GCP configuration for ${CLUSTER_TYPE}"
    exit
fi

CONFIG="{SHARED_DIR}/install-config.yaml"

cluster_variant=
if [[ -e "${SHARED_DIR}/install-config-variant.txt" ]]; then
    cluster_variant=$(<"${SHARED_DIR}/install-config-variant.txt")
fi

function has_variant() {
    regex="(^|,)$1($|,)"
    if [[ $cluster_variant =~ $regex ]]; then
        return 0
    fi
    return 1
}

base_domain=
if [[ -e "${SHARED_DIR}/install-config-base-domain.txt" ]]; then
    base_domain=$(<"${SHARED_DIR}/install-config-base-domain.txt")
else
    base_domain=origin-ci-int-gce.dev.openshift.com
fi

workers=3
if has_variant compact; then
    workers=0
fi

gcp_region=us-east1
gcp_project=openshift-gce-devel-ci
# HACK: try to "poke" the token endpoint before the test starts
for i in $(seq 1 30); do
    code="$( curl -s -o /dev/null -w "%{http_code}" https://oauth2.googleapis.com/token -X POST -d '' || echo "Failed to POST https://oauth2.googleapis.com/token with $?" 1>&2)"
    if [[ "${code}" == "400" ]]; then
        break
    fi
    echo "error: Unable to resolve https://oauth2.googleapis.com/token: $code" 1>&2
    if [[ "${i}" == "30" ]]; then
        echo "error: Unable to resolve https://oauth2.googleapis.com/token within timeout, exiting" 1>&2
        exit 1
    fi
    sleep 1
done
network=""
ctrlsubnet=""
computesubnet=""
if has_variant shared-vpc; then
    network="do-not-delete-shared-network"
    ctrlsubnet="do-not-delete-shared-master-subnet"
    computesubnet="do-not-delete-shared-worker-subnet"
fi
cat >> "${CONFIG}" << EOF
baseDomain: ${base_domain}
controlPlane:
  name: master
  replicas: 3
compute:
- name: worker
  replicas: ${workers}
platform:
  gcp:
    projectID: ${gcp_project}
    region: ${gcp_region}
    network: ${network}
    controlPlaneSubnet: ${ctrlsubnet}
    computeSubnet: ${computesubnet}
EOF

# TODO proxy variant
# TODO mirror variant
# TODO CLUSTER_NETWORK_MANIFEST
