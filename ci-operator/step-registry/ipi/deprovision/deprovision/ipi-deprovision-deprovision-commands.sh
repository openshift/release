#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deprovisioning cluster ..."
openshift-install --dir ${ARTIFACT_DIR}/installer destroy cluster
