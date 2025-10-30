#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
mkdir /tmp/installer
cp "${SHARED_DIR}"/metadata.json /tmp/installer/
openshift-install destroy cluster --dir /tmp/installer/ &
wait "$!"
