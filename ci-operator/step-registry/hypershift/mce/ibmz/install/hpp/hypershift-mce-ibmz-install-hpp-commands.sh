#!/usr/bin/env bash

set -ex

# Allow callers to redirect oc commands to a different cluster by setting
# INSTALL_KUBECONFIG. Empty = use ci-operator default.
if [[ -n "${INSTALL_KUBECONFIG:-}" ]]; then
  export KUBECONFIG="${INSTALL_KUBECONFIG}"
fi

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
  storagePools:
    - pvcTemplate:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 100Gi
      name: local
      path: "/var/hpvolumes"
  imagePullPolicy: IfNotPresent
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

# Wait for HPP pool daemonset/deployments/pods to be ready
echo "Waiting for HPP pool pods (hpp-pool-*) in openshift-cnv to be Running and Ready..."
HPP_TIMEOUT=600
HPP_INTERVAL=10
HPP_ELAPSED=0
while [[ ${HPP_ELAPSED} -lt ${HPP_TIMEOUT} ]]; do
  HPP_PODS=$(oc get po -n openshift-cnv --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep '^hpp-pool-' || true)
  if [[ -n "${HPP_PODS}" ]]; then
    NOT_RUNNING=$(oc get po -n openshift-cnv --no-headers 2>/dev/null | grep '^hpp-pool-' | grep -v ' Running ' || true)
    if [[ -z "${NOT_RUNNING}" ]]; then
      echo "All HPP pool pods are running:"
      oc get po -n openshift-cnv -l k8s-app=hostpath-provisioner -o wide || oc get po -n openshift-cnv | grep '^hpp-pool-' || true
      break
    fi
  fi
  echo "HPP pool pods not ready yet (${HPP_ELAPSED}s elapsed), waiting..."
  sleep ${HPP_INTERVAL}
  HPP_ELAPSED=$((HPP_ELAPSED + HPP_INTERVAL))
done

if [[ ${HPP_ELAPSED} -ge ${HPP_TIMEOUT} ]]; then
  echo "WARNING/ERROR: HPP pool pods did not become ready within ${HPP_TIMEOUT}s"
  oc get po -n openshift-cnv | grep '^hpp-pool-' || true
  oc get pvc -n openshift-cnv | grep '^hpp-pool-' || true
  oc get po -n openshift-cnv --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep '^hpp-pool-' | xargs -r oc describe po -n openshift-cnv || true
  exit 1
fi

# List all storage classes to confirm default
echo "All storage classes:"
oc get storageclass

echo "HostPathProvisioner and StorageClass configuration completed successfully!"
