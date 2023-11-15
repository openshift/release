#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

TEMPLATE_SRC_LOCAL=/var/lib/openshift-install/upi/aws/cloudformation

TEMPLATE_STACK_VPC="01_vpc.yaml"
TEMPLATE_STACK_LOCAL_ZONE="01.99_net_local-zone.yaml"

cp -v ${TEMPLATE_SRC_LOCAL}/${TEMPLATE_STACK_VPC} "${SHARED_DIR}"/${TEMPLATE_STACK_VPC} || true
cp -v ${TEMPLATE_SRC_LOCAL}/${TEMPLATE_STACK_LOCAL_ZONE} "${SHARED_DIR}"/${TEMPLATE_STACK_LOCAL_ZONE} || true

ls -la "${SHARED_DIR}"