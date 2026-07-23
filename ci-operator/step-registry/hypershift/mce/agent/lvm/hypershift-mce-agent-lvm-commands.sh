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

# Auto-detect namespace based on cluster version if not explicitly set
# Use the same approach as in step-registry/operatorhub/subscribe/lvm-operator/operatorhub-subscribe-lvm-operator-commands.sh
if [[ -z "${LVM_CLUSTER_NAMESPACE}" ]]; then
  CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1-2)
  MINOR_VERSION=$(echo "$CLUSTER_VERSION" | cut -d. -f2)

  echo "Detected OpenShift version: ${CLUSTER_VERSION}"

  # For OpenShift 4.20+, use openshift-lvm-storage, otherwise use openshift-storage
  if [[ ${MINOR_VERSION} -ge 20 ]]; then
    LVM_CLUSTER_NAMESPACE="openshift-lvm-storage"
  else
    LVM_CLUSTER_NAMESPACE="openshift-storage"
  fi

  echo "Auto-detected namespace: ${LVM_CLUSTER_NAMESPACE}"
else
  echo "Using explicitly set namespace: ${LVM_CLUSTER_NAMESPACE}"
fi

oc apply -f - <<EOF
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: my-lvmcluster
  namespace: ${LVM_CLUSTER_NAMESPACE}
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
    done < <(oc get pod -n "${LVM_CLUSTER_NAMESPACE}" | awk '/(topolvm-node-|vg-manager-)/{print $0}')

    echo "All pods are running."
    break
done

# Ensure no storage class is the default one for the cluster
for sc in $(oc get storageclass -o name); do
    oc annotate "$sc" storageclass.kubernetes.io/is-default-class-
done
# Ensure the lvm storage class is the default one for the cluster
oc annotate sc lvms-vg1 storageclass.kubernetes.io/is-default-class=true --overwrite

#oc wait lvmcluster -n "${LVM_CLUSTER_NAMESPACE}" -storage my-lvmcluster --for=jsonpath='{.status.state}'=Ready --timeout=20m