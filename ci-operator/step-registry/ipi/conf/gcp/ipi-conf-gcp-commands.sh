#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

GCP_BASE_DOMAIN="origin-ci-int-gce.dev.openshift.com"
GCP_PROJECT="openshift-gce-devel-ci"
GCP_REGION="${LEASED_RESOURCE}"

cat >> "${CONFIG}" << EOF
baseDomain: ${GCP_BASE_DOMAIN}
platform:
  gcp:
    projectID: ${GCP_PROJECT}
    region: ${GCP_REGION}
EOF
