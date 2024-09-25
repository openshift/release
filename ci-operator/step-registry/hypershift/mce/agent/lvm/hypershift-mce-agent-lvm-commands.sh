#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

if [ -f "${SHARED_DIR}/packet-conf.sh" ]; then
  source "${SHARED_DIR}/packet-conf.sh"
fi

LVM_DEVICE_PATH="/dev/vda"
if [ -f "${SHARED_DIR}/lvmdevice" ]; then
  LVM_DEVICE_PATH=$(<"${SHARED_DIR}/lvmdevice")
fi

oc apply -f - <<EOF
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: my-lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
    - name: vg1
      deviceSelector:
        paths:
        - ${LVM_DEVICE_PATH}
      default: true
      thinPoolConfig:
        name: thin-pool-1
        sizePercent: 90
        overprovisionRatio: 10
EOF

while true; do
    while IFS= read -r line; do
        status=$(echo "$line" | awk '{print $3}')
        if [[ $status != "Running" ]]; then
            echo "Waiting for pods to be running..."
            sleep 10
            continue 2  # Continue the outer loop
        fi
    done < <(oc get pod -n openshift-storage | awk '/(topolvm-node-|vg-manager-)/{print $0}')

    echo "All pods are running."
    break
done

# Ensure no storage class is the default one for the cluster
for sc in $(oc get storageclass -o name); do
    oc annotate "$sc" storageclass.kubernetes.io/is-default-class-
done
# Ensure the lvm storage class is the default one for the cluster
oc annotate sc lvms-vg1 storageclass.kubernetes.io/is-default-class=true --overwrite

#oc wait lvmcluster -n openshift-storage my-lvmcluster --for=jsonpath='{.status.state}'=Ready --timeout=20m