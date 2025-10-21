#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

echo "Creating manifests to set osImageURL to the relevant RHCOS 10 version"

cat > "${SHARED_DIR}/manifest_rhcos10_worker.yaml" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: os-layer-custom-worker
spec:
  osImageURL: quay.io/openshift-release-dev/ocp-v4.0-art-dev:4.20-10.1-node-image
  baseOSExtensionsContainerImage: quay.io/openshift-release-dev/ocp-v4.0-art-dev:4.20-10.1-node-image-extensions

EOF

cat > "${SHARED_DIR}/manifest_rhcos10_master.yaml" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: os-layer-custom-master
spec:
  osImageURL: quay.io/openshift-release-dev/ocp-v4.0-art-dev:4.20-10.1-node-image
  baseOSExtensionsContainerImage: quay.io/openshift-release-dev/ocp-v4.0-art-dev:4.20-10.1-node-image-extensions

EOF

