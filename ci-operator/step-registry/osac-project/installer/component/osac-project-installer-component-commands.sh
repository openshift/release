#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ osac-installer-component commands ************"
echo "--- Running with the following parameters ---"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "E2E_KUSTOMIZE_OVERLAY: ${E2E_KUSTOMIZE_OVERLAY}"
echo "E2E_VM_TEMPLATE: ${E2E_VM_TEMPLATE}"
echo "OSAC_INSTALLER_IMAGE: ${OSAC_INSTALLER_IMAGE}"
echo "COMPONENT_IMAGE: ${COMPONENT_IMAGE}"
echo "COMPONENT_IMAGE_NAME: ${COMPONENT_IMAGE_NAME}"
echo "AAP_EE_IMAGE_OVERRIDE: ${AAP_EE_IMAGE_OVERRIDE:-}"
echo "-------------------------------------------"

base64 -d /var/run/osac-installer-aap/license > /tmp/license.zip

timeout -s 9 10m scp -F "${SHARED_DIR}/ssh_config" /tmp/license.zip ci_machine:/tmp/license.zip

timeout -s 9 120m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << EOF|& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

export KUBECONFIG=\$(find \${KUBECONFIG} -type f -print -quit)

oc annotate sc lvms-vg1 storageclass.kubernetes.io/is-default-class=true --overwrite

echo "Waiting for OpenShift Virtualization to be ready..."
oc wait --for=condition=Available hyperconverged/kubevirt-hyperconverged -n openshift-cnv --timeout=900s

cat <<NADEOF | oc apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: default
  namespace: openshift-ovn-kubernetes
spec:
  config: '{"cniVersion": "0.4.0", "name": "ovn-kubernetes", "type": "ovn-k8s-cni-overlay"}'
NADEOF

podman run --authfile /root/pull-secret --rm --network=host \
-v \${KUBECONFIG}:/root/.kube/config:z \
-v /root/pull-secret:/installer/overlays/${E2E_KUSTOMIZE_OVERLAY}/files/quay-pull-secret.json:z \
-v /tmp/license.zip:/installer/overlays/${E2E_KUSTOMIZE_OVERLAY}/files/license.zip:z \
-e INSTALLER_NAMESPACE=${E2E_NAMESPACE} \
-e INSTALLER_KUSTOMIZE_OVERLAY=${E2E_KUSTOMIZE_OVERLAY} \
-e INSTALLER_VM_TEMPLATE=${E2E_VM_TEMPLATE} \
-e COMPONENT_IMAGE=${COMPONENT_IMAGE} \
-e COMPONENT_IMAGE_NAME=${COMPONENT_IMAGE_NAME} \
-e AAP_EE_IMAGE_OVERRIDE=${AAP_EE_IMAGE_OVERRIDE:-} \
${OSAC_INSTALLER_IMAGE} sh -c '
set -euo pipefail

COMPONENT_REGISTRY=\${COMPONENT_IMAGE%:*}
COMPONENT_TAG=\${COMPONENT_IMAGE##*:}

echo "Overriding image \${COMPONENT_IMAGE_NAME} -> \${COMPONENT_IMAGE}"
cd /installer/base

if ! grep -Fq "name: \${COMPONENT_IMAGE_NAME}" kustomization.yaml; then
  echo "ERROR: image name \${COMPONENT_IMAGE_NAME} not found in /installer/base/kustomization.yaml" >&2
  cat kustomization.yaml >&2
  exit 1
fi

if grep -A1 "name: \${COMPONENT_IMAGE_NAME}" kustomization.yaml | grep -q "newName:"; then
  sed -i "\#name: \${COMPONENT_IMAGE_NAME}#,/newTag:/{
    s|newName:.*|newName: \${COMPONENT_REGISTRY}|
    s|newTag:.*|newTag: \${COMPONENT_TAG}|
  }" kustomization.yaml
else
  sed -i "\#name: \${COMPONENT_IMAGE_NAME}#{
    a\\  newName: \${COMPONENT_REGISTRY}
    n
    s|newTag:.*|newTag: \${COMPONENT_TAG}|
  }" kustomization.yaml
fi

if ! grep -Fq "\${COMPONENT_REGISTRY}" kustomization.yaml || ! grep -Fq "newTag: \${COMPONENT_TAG}" kustomization.yaml; then
  echo "ERROR: kustomize image override failed — expected \${COMPONENT_REGISTRY}:\${COMPONENT_TAG}" >&2
  cat kustomization.yaml >&2
  exit 1
fi

if [ -n "\${AAP_EE_IMAGE_OVERRIDE}" ]; then
  overlay_file="/installer/overlays/\${INSTALLER_KUSTOMIZE_OVERLAY}/kustomization.yaml"
  if ! grep -q "AAP_EE_IMAGE=" "\${overlay_file}"; then
    echo "ERROR: AAP_EE_IMAGE entry not found in \${overlay_file}" >&2
    exit 1
  fi
  echo "Overriding AAP_EE_IMAGE -> \${COMPONENT_IMAGE}"
  sed -i "s|AAP_EE_IMAGE=.*|AAP_EE_IMAGE=\${COMPONENT_IMAGE}|" "\${overlay_file}"
fi

cd /installer
sh scripts/setup.sh
'

EOF
