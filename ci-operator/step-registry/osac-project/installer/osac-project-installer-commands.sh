#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ osac-installer commands ************"
echo "--- Running with the following parameters ---"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "E2E_KUSTOMIZE_OVERLAY: ${E2E_KUSTOMIZE_OVERLAY}"
echo "E2E_VM_TEMPLATE: ${E2E_VM_TEMPLATE}"
echo "OSAC_INSTALLER_IMAGE: ${OSAC_INSTALLER_IMAGE}"
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
${OSAC_INSTALLER_IMAGE} sh /installer/scripts/setup.sh

EOF
