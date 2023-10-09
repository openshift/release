#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-51094"

# Setting clusterOSImage
ocp_version="${BUILD_VERSION:1:4}"
cluster_os_image=$(curl -s https://raw.githubusercontent.com/openshift/installer/release-"$ocp_version"/data/data/coreos/rhcos.json | jq -r '.architectures.x86_64.artifacts.nutanix.formats.qcow2.disk.location')

sed "s#nutanix:#nutanix:\n    clusterOSImage: $cluster_os_image#g" "${SHARED_DIR}/install-config.yaml"
cat "${SHARED_DIR}/install-config.yaml"

# Restore
# Restore
