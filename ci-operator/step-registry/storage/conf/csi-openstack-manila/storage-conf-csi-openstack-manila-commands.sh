#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ -z "${TEST_CSI_DRIVER_MANIFEST}" || "${TEST_CSI_DRIVER_MANIFEST}" != *"manila"* ]]; then
    echo "TEST_CSI_DRIVER_MANIFEST is empty or doesn't contain manila, skipping the step"
    exit 0
fi

if [ -d /go/src/github.com/openshift/csi-operator/ ]; then
    echo "Using csi-operator repo"
    cd /go/src/github.com/openshift/csi-operator/
    cp test/e2e/openstack-manila/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
else
    echo "Using regular csi directory"
    cd /go/src/github.com/openshift/csi-driver-manila-operator
    cp test/e2e/manifest.yaml ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

# For DHSS=true environments (driver_handles_share_servers=true), we need to create
# a new StorageClass with the shareNetworkID parameter. StorageClass parameters are
# immutable, so we can't patch the existing csi-manila-default StorageClass.
if [[ -n "${MANILA_SHARE_NETWORK_ID:-}" ]]; then
    echo "MANILA_SHARE_NETWORK_ID is set to: ${MANILA_SHARE_NETWORK_ID}"
    echo "Creating new StorageClass with shareNetworkID for DHSS=true environment"

    # Get the existing StorageClass configuration and create a new one with shareNetworkID
    cat > ${SHARED_DIR}/manila-sharenetwork-storageclass.yaml << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: csi-manila-sharenetwork
provisioner: manila.csi.openstack.org
allowVolumeExpansion: true
parameters:
  type: default
  shareNetworkID: "${MANILA_SHARE_NETWORK_ID}"
  csi.storage.k8s.io/provisioner-secret-name: csi-manila-secrets
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-manila-csi-driver
  csi.storage.k8s.io/node-stage-secret-name: csi-manila-secrets
  csi.storage.k8s.io/node-stage-secret-namespace: openshift-manila-csi-driver
  csi.storage.k8s.io/node-publish-secret-name: csi-manila-secrets
  csi.storage.k8s.io/node-publish-secret-namespace: openshift-manila-csi-driver
  csi.storage.k8s.io/controller-expand-secret-name: csi-manila-secrets
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-manila-csi-driver
EOF

    echo "StorageClass manifest created at ${SHARED_DIR}/manila-sharenetwork-storageclass.yaml:"
    cat ${SHARED_DIR}/manila-sharenetwork-storageclass.yaml

    # Apply the StorageClass to the cluster
    echo "Applying StorageClass to the cluster..."
    oc apply -f ${SHARED_DIR}/manila-sharenetwork-storageclass.yaml

    # Update the test manifest to use the new StorageClass
    sed -i 's/FromExistingClassName: csi-manila-default/FromExistingClassName: csi-manila-sharenetwork/' ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
fi

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
