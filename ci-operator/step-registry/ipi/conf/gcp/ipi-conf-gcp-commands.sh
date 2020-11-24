#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

GCP_BASE_DOMAIN="origin-ci-int-gce.dev.openshift.com"
GCP_PROJECT="openshift-gce-devel-ci"
GCP_REGION="us-east1"

cat >> "${CONFIG}" << EOF
baseDomain: ${GCP_BASE_DOMAIN}
compute:
- name: worker
  replicas: ${COMPUTE_REPLICAS}
platform:
  gcp:
    projectID: ${GCP_PROJECT}
    region: ${GCP_REGION}
EOF
