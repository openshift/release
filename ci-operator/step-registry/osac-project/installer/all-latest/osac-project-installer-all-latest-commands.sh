#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ osac-installer-all-latest commands ************"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "E2E_KUSTOMIZE_OVERLAY: ${E2E_KUSTOMIZE_OVERLAY}"
echo "E2E_VM_TEMPLATE: ${E2E_VM_TEMPLATE}"
echo "OSAC_INSTALLER_IMAGE: ${OSAC_INSTALLER_IMAGE}"
echo "FULFILLMENT_IMAGE: ${FULFILLMENT_IMAGE}"
echo "OPERATOR_IMAGE: ${OPERATOR_IMAGE}"
echo "AAP_IMAGE: ${AAP_IMAGE}"
echo "-------------------------------------------"

base64 -d /var/run/osac-installer-aap/license > /tmp/license.zip

timeout -s 9 10m scp -F "${SHARED_DIR}/ssh_config" /tmp/license.zip ci_machine:/tmp/license.zip

timeout -s 9 120m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << EOF|& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -euo pipefail

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
${OSAC_INSTALLER_IMAGE} sh -c '
set -euo pipefail

echo "=== Installing kustomize ==="
curl -fsSL https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.6.0/kustomize_v5.6.0_linux_amd64.tar.gz | tar xzf - -C /usr/local/bin

echo "=== Overriding fulfillment-service image ==="
cd /installer/base
kustomize edit set image ghcr.io/osac-project/fulfillment-service=${FULFILLMENT_IMAGE}

echo "=== Overriding osac-operator image ==="
kustomize edit set image ghcr.io/osac-project/osac-operator=${OPERATOR_IMAGE}

echo "=== Overriding AAP EE image ==="
cd /installer
sed -i "s|AAP_EE_IMAGE=.*|AAP_EE_IMAGE=${AAP_IMAGE}|" overlays/${E2E_KUSTOMIZE_OVERLAY}/kustomization.yaml
sed -i "s|AAP_PROJECT_GIT_BRANCH=.*|AAP_PROJECT_GIT_BRANCH=main|" overlays/${E2E_KUSTOMIZE_OVERLAY}/kustomization.yaml

echo "=== Running setup.sh with all overrides ==="
sh scripts/setup.sh
'

EOF
