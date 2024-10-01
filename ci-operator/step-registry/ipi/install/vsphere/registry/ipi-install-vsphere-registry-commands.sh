#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

#Create pvc for image registry storage
if [[ "${SETUP_IMAGE_REGISTRY_WITH_PVC:-}" == "true" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Setting the image registry storage to use the manual setting storage..."
  cat >> "${SHARED_DIR}/registry-pvc.yaml" << EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-pvc
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF
  oc create -f "${SHARED_DIR}/registry-pvc.yaml" -n openshift-image-registry &&
  oc patch config.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"managementState":"Managed","rolloutStrategy":"Recreate","replicas":1,"storage":{"managementState":"Managed","pvc":{"claim":"registry-pvc"}}}}'
else
  echo "$(date -u --rfc-3339=seconds) - Configuring image registry with emptyDir..."
  oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
fi

echo "$(date -u --rfc-3339=seconds) - Wait for the imageregistry operator to see that it has work to do..."
sleep 30

echo "$(date -u --rfc-3339=seconds) - Wait for the imageregistry operator to go available..."
oc wait --all --for=condition=Available=True clusteroperators.config.openshift.io --timeout=10m

echo "$(date -u --rfc-3339=seconds) - Wait for the imageregistry to rollout..."
oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io --timeout=30m

echo "$(date -u --rfc-3339=seconds) - Wait until imageregistry config changes are observed by kube-apiserver..."
sleep 60

echo "$(date -u --rfc-3339=seconds) - Waits for kube-apiserver to finish rolling out..."
oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io --timeout=30m

oc wait --all --for=condition=Degraded=False clusteroperators.config.openshift.io --timeout=1m

function setE2eMirror() {
# Maps e2e images on dockerhub to locally hosted mirror

  oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 98-e2e-registry-mirror
spec:
  config:
    ignition:
      version: 3.1.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,dW5xdWFsaWZpZWQtc2VhcmNoLXJlZ2lzdHJpZXMgPSBbInJlZ2lzdHJ5LmFjY2Vzcy5yZWRoYXQuY29tIiwgImRvY2tlci5pbyJdCgpbW3JlZ2lzdHJ5XV0KcHJlZml4ID0gImRvY2tlci5pbyIKbG9jYXRpb24gPSAiZG9ja2VyLmlvIgoKW1tyZWdpc3RyeS5taXJyb3JdXQpsb2NhdGlvbiA9ICJlMmUtY2FjaGUudm1jLWNpLmRldmNsdXN0ZXIub3BlbnNoaWZ0LmNvbTo1MDAwIgo=
        mode: 0544
        overwrite: true
        path: /etc/containers/registries.conf
EOF

  echo "Waiting for machineconfig to begin rolling out"
  oc wait --for=condition=Updating mcp/worker --timeout=5m

  echo "Waiting for machineconfig to finish rolling out"
  oc wait --for=condition=Updated mcp/worker --timeout=30m
}

if [[ "$JOB_NAME" == *"4.6-e2e"* ]]; then
  echo "Remapping dockerhub e2e images to local mirror for 4.6 e2e vSphere jobs"
  setE2eMirror

elif [[ $JOB_NAME =~ .*okd-scos-4.*-e2e-vsphere.* ]]; then
  echo "Remapping dockerhub e2e images to local mirror for OKD e2e vSphere jobs"

  oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 98-e2e-registry-mirror
spec:
  config:
    ignition:
      version: 3.1.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,dW5xdWFsaWZpZWQtc2VhcmNoLXJlZ2lzdHJpZXMgPSBbInJlZ2lzdHJ5LmFjY2Vzcy5yZWRoYXQuY29tIiwgImRvY2tlci5pbyJdCgpbW3JlZ2lzdHJ5XV0KcHJlZml4ID0gImRvY2tlci5pby9vcGVubGliZXJ0eSIKbG9jYXRpb24gPSAicXVheS5pby9vY3Atc3BsYXQiCgo=
        mode: 0544
        overwrite: true
        path: /etc/containers/registries.conf
EOF

  echo "Waiting for machineconfig to begin rolling out"
  oc wait --for=condition=Updating mcp/worker --timeout=5m

  echo "Waiting for machineconfig to finish rolling out"
  oc wait --for=condition=Updated mcp/worker --timeout=30m
fi

