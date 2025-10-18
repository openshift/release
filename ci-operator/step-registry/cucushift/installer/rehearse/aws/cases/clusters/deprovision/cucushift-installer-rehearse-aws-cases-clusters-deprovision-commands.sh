#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

mkdir /tmp/installer
cp "${SHARED_DIR}"/metadata.json /tmp/installer/
openshift-install destroy cluster --dir /tmp/installer/ &
wait "$!"
