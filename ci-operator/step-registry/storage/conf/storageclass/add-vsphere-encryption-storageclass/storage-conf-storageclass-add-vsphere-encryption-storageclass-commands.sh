#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
    echo "setting the proxy"
    echo "source ${SHARED_DIR}/proxy-conf.sh"
    source "${SHARED_DIR}/proxy-conf.sh"
else
    echo "no proxy setting."
fi

DATA_STORE_URL=$(oc -n openshift-cluster-csi-drivers exec deployment/vmware-vsphere-csi-driver-controller -c csi-driver -- cat /etc/kubernetes/vsphere-csi-config/cloud.conf|grep -Eo 'ds:///.*/$')
echo "Default datastore is: \"${DATA_STORE_URL}\""

oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${REQUIRED_ENCRYPTION_STORAGECLASS_NAME}
parameters:
  # Using the vsphere preset encrypt storage policy
  storagePolicyName: ${REQUIRED_ENCRYPTION_POLICY}
  datastoreurl: ${DATA_STORE_URL}
provisioner: csi.vsphere.vmware.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
