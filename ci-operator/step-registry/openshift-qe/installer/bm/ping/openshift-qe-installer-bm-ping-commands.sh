#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

bastion=$(cat "/secret/address")
ls -l ${CLUSTER_PROFILE_DIR}/pull_secret
oc adm release info $RELEASE_IMAGE_LATEST -a ${CLUSTER_PROFILE_DIR}/pull_secret

ping -c 5 $bastion
