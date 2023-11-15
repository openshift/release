#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#
# Multi-layer step used in presubmits to copy artifacts from build image
# to be used in the later steps.
#

TEMPLATE_SRC_LOCAL=/var/lib/openshift-install/upi/aws/cloudformation
TEMPLATES=()
TEMPLATES+=( "01_vpc.yaml" )
TEMPLATES+=( "01.99_net_local-zone.yaml" )

for TEMPLATE in "${TEMPLATES[@]}"; do
    cp -v "${TEMPLATE_SRC_LOCAL}/${TEMPLATE}" "${SHARED_DIR}/${TEMPLATE}" || true
done