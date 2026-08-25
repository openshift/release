#!/usr/bin/env bash

set -ex

# This step always targets the infra cluster. Use INSTALL_KUBECONFIG if
# explicitly set; otherwise fall back to $SHARED_DIR/infra-kubeconfig.
# NOTE: env var defaults in ref YAMLs are not shell-expanded, so the path
# cannot be defaulted in the ref — we resolve it here at runtime instead.
EFFECTIVE_KUBECONFIG="${INSTALL_KUBECONFIG:-${SHARED_DIR}/infra-kubeconfig}"
if [[ ! -f "${EFFECTIVE_KUBECONFIG}" ]]; then
  echo "ERROR: infra kubeconfig not found at ${EFFECTIVE_KUBECONFIG}"
  exit 1
fi
export KUBECONFIG="${EFFECTIVE_KUBECONFIG}"

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
spec:
  imagePullPolicy: IfNotPresent
  pathConfig:
    path: "/var/hpvolumes"
    useNamingPrefix: false
EOF

# Wait for HostPathProvisioner to be ready
echo "Waiting for HostPathProvisioner to be ready..."
oc wait pod -l app=hostpath-provisioner -n openshift-cnv --for=condition=Ready --timeout=5m || true

# Get the storage pool name from HostPathProvisioner CR
# If not found, use the default
ACTUAL_POOL_NAME="${STORAGE_POOL_NAME}"
if oc get hostpathprovisioner hostpath-provisioner -A &>/dev/null; then
  ACTUAL_POOL_NAME=$(oc get hostpathprovisioner hostpath-provisioner -A -o yaml | \
    grep -A 5 "pathConfig:" | grep "path:" | awk '{print $NF}' | sed 's|/var/hpvolumes/||' || echo "${STORAGE_POOL_NAME}")
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

# List all storage classes to confirm default
echo "All storage classes:"
oc get storageclass

echo "HostPathProvisioner and StorageClass configuration completed successfully!"
