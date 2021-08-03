#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export STORAGEClASS_LOCATION=${SHARED_DIR}/efs-sc.yaml
export MANIFEST_LOCATION=${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}

/usr/bin/create-efs-volume start

echo "Using storageclass ${STORAGEClASS_LOCATION}"
cat ${STORAGEClASS_LOCATION}

oc create -f ${STORAGEClASS_LOCATION}
echo "Created storageclass from file ${STORAGEClASS_LOCATION}"

oc create -f - <<EOF
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
    name: efs.csi.aws.com
spec:
  managementState: Managed
EOF

echo "Created cluster CSI driver object"

# For debugging
echo "Using ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}:"
cat ${SHARED_DIR}/${TEST_CSI_DRIVER_MANIFEST}
