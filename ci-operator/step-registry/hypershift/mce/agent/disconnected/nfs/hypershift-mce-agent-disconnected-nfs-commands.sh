#!/bin/bash

set -ex

echo "************ MCE agent disconnected nfs command ************"

source "${SHARED_DIR}/packet-conf.sh"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF
set -xeo pipefail

echo "1. Get mirror registry"
mirror_registry=\$(oc get imagecontentsourcepolicy -o json | jq -r '.items[].spec.repositoryDigestMirrors[0].mirrors[0]')
mirror_registry=\${mirror_registry%%/*}
if [[ \$mirror_registry == "" ]] ; then
    echo "Warning: Can not find the mirror registry, abort !!!"
    exit 0
fi
echo "mirror registry is \${mirror_registry}"

echo "2. oc mirror nfs image and config ICSP"
oc image mirror quay.io/openshifttest/nfs-provisioner@sha256:f402e6039b3c1e60bf6596d283f3c470ffb0a1e169ceb8ce825e3218cd66c050 \${mirror_registry}/openshifttest/nfs-provisioner:latest
cat << END | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: nfs-repo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - \${mirror_registry}/openshifttest
    source: quay.io/openshifttest
END

echo "3. deploy nfs provisioner"
curl https://raw.githubusercontent.com/LiangquanLi930/deployhypershift/main/deploy_nfs_provisioner.sh | bash -x

set -x
EOF