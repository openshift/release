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

# Create HostPathProvisioner CR if it doesn't exist.
# STORAGE_POOL_NAME must match the StorageClass parameters.storagePool value.
POOL_NAME="${STORAGE_POOL_NAME:-local}"
echo "$(date) Creating HostPathProvisioner CR with storage pool name=${POOL_NAME}"
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
      name: ${POOL_NAME}
      path: "/var/hpvolumes"
  imagePullPolicy: IfNotPresent
EOF

echo "$(date) HostPathProvisioner CR:"
oc get hostpathprovisioner hostpath-provisioner -n openshift-cnv -o yaml || true

# Wait for HostPathProvisioner controller pods
echo "$(date) Waiting for HostPathProvisioner controller pods to be Ready..."
oc wait pod -l app=hostpath-provisioner -n openshift-cnv --for=condition=Ready --timeout=5m || true

# Prefer the pool name actually present on the CR (namespace openshift-cnv).
ACTUAL_POOL_NAME="${POOL_NAME}"
if oc get hostpathprovisioner hostpath-provisioner -n openshift-cnv &>/dev/null; then
  ACTUAL_POOL_NAME=$(oc get hostpathprovisioner hostpath-provisioner -n openshift-cnv \
    -o jsonpath='{.spec.storagePools[0].name}' 2>/dev/null || echo "${POOL_NAME}")
fi
echo "$(date) Using storage pool name for StorageClass: ${ACTUAL_POOL_NAME}"

echo "$(date) Creating StorageClass ${STORAGE_CLASS_NAME}..."
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

echo "$(date) Marking ${STORAGE_CLASS_NAME} as default storage class..."
oc patch storageclass ${STORAGE_CLASS_NAME} -p \
  '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo "$(date) Verifying StorageClass configuration..."
oc get storageclass ${STORAGE_CLASS_NAME} -o yaml | grep -A 2 "annotations:" || true

# Wait until every hpp-pool-* pod is Ready (not just Running).
# Running without Ready means the CSI/HPP sidecar is still failing and VMs would hang on PVC bind.
echo "$(date) Waiting for HPP pool pods (hpp-pool-*) in openshift-cnv to be Ready..."
HPP_TIMEOUT=600
HPP_INTERVAL=10
HPP_ELAPSED=0
HPP_READY=false
while [[ ${HPP_ELAPSED} -lt ${HPP_TIMEOUT} ]]; do
  HPP_PODS=$(oc get po -n openshift-cnv --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep '^hpp-pool-' || true)
  if [[ -z "${HPP_PODS}" ]]; then
    echo "$(date) No hpp-pool-* pods yet (${HPP_ELAPSED}s/${HPP_TIMEOUT}s)"
  else
    NOT_READY=""
    while IFS= read -r pod; do
      [[ -z "${pod}" ]] && continue
      ready=$(oc get po -n openshift-cnv "${pod}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
      phase=$(oc get po -n openshift-cnv "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      echo "$(date)   pod=${pod} phase=${phase:-?} Ready=${ready:-?}"
      if [[ "${ready}" != "True" ]]; then
        NOT_READY="${NOT_READY} ${pod}"
      fi
    done <<< "${HPP_PODS}"
    if [[ -z "${NOT_READY}" ]]; then
      echo "$(date) All HPP pool pods are Ready:"
      oc get po -n openshift-cnv | grep '^hpp-pool-' || true
      HPP_READY=true
      break
    fi
    echo "$(date) HPP pods not Ready yet:${NOT_READY}"
  fi
  sleep ${HPP_INTERVAL}
  HPP_ELAPSED=$((HPP_ELAPSED + HPP_INTERVAL))
done

if [[ "${HPP_READY}" != "true" ]]; then
  echo "$(date) ERROR: HPP pool pods did not become Ready within ${HPP_TIMEOUT}s"
  oc get po -n openshift-cnv | grep '^hpp-pool-' || true
  oc get pvc -n openshift-cnv | grep '^hpp-pool-' || true
  oc get hostpathprovisioner -n openshift-cnv -o yaml || true
  oc get po -n openshift-cnv --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep '^hpp-pool-' | xargs -r -n1 oc describe po -n openshift-cnv || true
  exit 1
fi

echo "$(date) All storage classes:"
oc get storageclass

echo "$(date) HostPathProvisioner and StorageClass configuration completed successfully!"
