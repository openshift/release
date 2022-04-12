#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


echo "$(date -u --rfc-3339=seconds) - Creating PVC for Image Registry"
cat > "${SHARED_DIR}/image-registry-pvc.yaml" << EOF
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: image-registry-storage
  namespace: openshift-image-registry
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
EOF

oc create -f "${SHARED_DIR}/image-registry-pvc.yaml" -n openshift-image-registry
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"storage":{"pvc":{"claim":"image-registry-storage"}}}}'

echo "$(date -u --rfc-3339=seconds) - Changing rollout strategy for Image Registry"
oc patch config.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"rolloutStrategy":"Recreate","replicas":1}}'

echo "$(date -u --rfc-3339=seconds) - Changing management state for Image Registry Operator"
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"managementState":"Managed"}}'
