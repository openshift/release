#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

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
echo "$(date -u --rfc-3339=seconds) - Configuring image registry with pvc..."
oc patch config.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"managementState":"Managed","rolloutStrategy":"Recreate","replicas":1,"storage":{"managementState":"Managed","pvc":{"claim":"image-registry-storage"}}}}'
# wait image registry to redeploy with new set
check_imageregistry_back_ready(){
  local result="" iter=10 period=60
  while [[ "${result}" != "TrueFalse" && $iter -gt 0 ]]; do
    sleep $period
    result=$(oc get co image-registry -o=jsonpath='{.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}')
    (( iter -- ))
  done
  if [ "${result}" != "TrueFalse" ] ; then
    echo "Image registry failed to re-configure, please check the below resources"
    oc describe pods -l docker-registry=default -n openshift-image-registry
    oc get config.image/cluster -o yaml
    return 1
  else
    echo "Image registry configured nutanix object successfully"
    return 0
  fi
}
check_imageregistry_back_ready || exit 1