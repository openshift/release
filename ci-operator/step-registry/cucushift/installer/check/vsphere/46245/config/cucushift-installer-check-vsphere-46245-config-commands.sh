#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-46245"

CONFIG="${SHARED_DIR}/install-config.yaml"

# Set field platform.vsphere.diskType thin
sed -i "/vsphere:/a \ \ \ \ diskType: thin" "${CONFIG}"
cat "${CONFIG}"

# Restore
