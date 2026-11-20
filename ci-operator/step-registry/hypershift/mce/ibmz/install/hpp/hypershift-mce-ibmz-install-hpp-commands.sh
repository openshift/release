#!/usr/bin/env bash

set -ex

# Wait for OpenShift Virtualization operator to be ready
echo "Waiting for OpenShift Virtualization operator to be ready..."
oc wait deployment -n openshift-cnv virt-operator --for=condition=Available --timeout=10m

# Create HostPathProvisioner CR if it doesn't exist
echo "Creating HostPathProvisioner CR..."
oc apply -f - <<EOF
apiVersion: hostpathprovisioner.kubevirt.io/v1beta1
kind: HostPathProvisioner
metadata:
  name: hostpath-provisioner
  namespace: openshift-cnv
spec:
  imagePullPolicy: IfNotPresent
  storagePools:
    - name: local
      path: "/var/hpvolumes"
  workload:
    nodeSelector:
      kubernetes.io/os: linux
EOF

# Wait for HostPathProvisioner to be ready
echo "Waiting for HostPathProvisioner to be ready..."
oc wait pod -l app=hostpath-provisioner -n openshift-cnv --for=condition=Ready --timeout=5m || true

# Get the storage pool name from HostPathProvisioner CR (.spec.storagePools[].name)
# The StorageClass storagePool parameter must be the pool NAME, not the path.
ACTUAL_POOL_NAME="${STORAGE_POOL_NAME}"
if oc get hostpathprovisioner hostpath-provisioner &>/dev/null; then
  ACTUAL_POOL_NAME=$(oc get hostpathprovisioner hostpath-provisioner \
    -o jsonpath='{.spec.storagePools[0].name}' 2>/dev/null || echo "${STORAGE_POOL_NAME}")
fi

echo "Using storage pool name: ${ACTUAL_POOL_NAME}"

# Create StorageClass with HPP provisioner
echo "Creating StorageClass ${STORAGE_CLASS_NAME}..."
oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS_NAME}
provisioner: kubevirt.io.hostpath-provisioner
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  storagePool: ${ACTUAL_POOL_NAME}
EOF

# Mark the StorageClass as default
echo "Marking ${STORAGE_CLASS_NAME} as default storage class..."
oc patch storageclass ${STORAGE_CLASS_NAME} -p \
  '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Verify the StorageClass is default
echo "Verifying StorageClass configuration..."
oc get storageclass ${STORAGE_CLASS_NAME} -o yaml | grep -A 2 "annotations:"

# Wait for HPP CSI DaemonSet to be ready
echo "Waiting for HPP CSI DaemonSet in openshift-cnv to be ready..."
oc rollout status daemonset/hostpath-provisioner-csi -n openshift-cnv --timeout=10m
oc wait pod -l k8s-app=hostpath-provisioner -n openshift-cnv \
  --for=condition=Ready --timeout=5m || true

# List all storage classes to confirm default
echo "All storage classes:"
oc get storageclass

echo "HostPathProvisioner and StorageClass configuration completed successfully!"