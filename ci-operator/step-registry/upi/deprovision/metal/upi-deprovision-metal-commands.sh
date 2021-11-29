#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
export PATH=$PATH:/tmp/shared
echo "Deprovisioning cluster ..."
PACKET_AUTH_TOKEN=$(cat ${CLUSTER_PROFILE_DIR}/.packetcred)
export PACKET_AUTH_TOKEN
cd ${SHARED_DIR}/terraform && terraform init
cd ${SHARED_DIR}/terraform && terraform destroy -auto-approve
