#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ osac CaaS installer ************"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "E2E_KUSTOMIZE_OVERLAY: ${E2E_KUSTOMIZE_OVERLAY}"

base64 -d /var/run/osac-installer-aap/license > /tmp/license.zip

timeout -s 9 10m scp -F "${SHARED_DIR}/ssh_config" /tmp/license.zip ci_machine:/tmp/license.zip

timeout -s 9 120m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash - << EOF|& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

export KUBECONFIG=\$(find \${KUBECONFIG} -type f -print -quit)

oc annotate sc lvms-vg1 storageclass.kubernetes.io/is-default-class=true --overwrite

podman run --authfile /root/pull-secret --rm --network=host \
-v \${KUBECONFIG}:/root/.kube/config:z \
-v /root/pull-secret:/installer/overlays/${E2E_KUSTOMIZE_OVERLAY}/files/quay-pull-secret.json:z \
-v /tmp/license.zip:/installer/overlays/${E2E_KUSTOMIZE_OVERLAY}/files/license.zip:z \
-e INSTALLER_NAMESPACE=${E2E_NAMESPACE} \
-e INSTALLER_KUSTOMIZE_OVERLAY=${E2E_KUSTOMIZE_OVERLAY} \
-e MCE_SERVICE=true \
-e STORAGE_SERVICE=true \
-e INGRESS_SERVICE=true \
${OSAC_INSTALLER_IMAGE} sh /installer/scripts/setup.sh

EOF
