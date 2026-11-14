#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf idms command ************"

# Applied by baremetalds-devscripts-setup via ASSETS_EXTRA_FOLDER
# (files named manifest_*.yaml in SHARED_DIR).
cat > "${SHARED_DIR}/manifest_idms.yaml" << EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: disconnected-local-registry
spec:
  imageDigestMirrors:
  - source: quay.io/openshift-release-dev/ocp-v5.0-art-dev
    mirrors:
    - ${IDMS_MIRROR}
  - source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
    mirrors:
    - ${IDMS_MIRROR}
  - source: quay.io/openshift-release-dev/ocp-release
    mirrors:
    - ${IDMS_MIRROR}
EOF

echo "Wrote ${SHARED_DIR}/manifest_idms.yaml"
cat "${SHARED_DIR}/manifest_idms.yaml"
