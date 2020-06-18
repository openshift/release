#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted conf command ************"

echo "export NODES_PLATFORM=assisted" >> ${SHARED_DIR}/dev-scripts-additional-config
echo "export IP_STACK=v4" >> ${SHARED_DIR}/dev-scripts-additional-config
echo "export NUM_WORKERS=1" >> ${SHARED_DIR}/dev-scripts-additional-config
echo "export INSTALL_OPERATOR_SDK=0" >> ${SHARED_DIR}/dev-scripts-additional-config
echo "export TEST_INFRA_BRANCH=igal/new_skipper" >> ${SHARED_DIR}/dev-scripts-additional-config

echo "assisted" >> ${SHARED_DIR}/makefile-target
