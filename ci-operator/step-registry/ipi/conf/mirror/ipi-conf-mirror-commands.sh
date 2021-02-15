#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
mkdir -p ${HOME}/.docker
cp ${CLUSTER_PROFILE_DIR}/pull-secret ${HOME}/.docker/config.json
oc registry login
MIRROR_BASE=$( oc get is release -o 'jsonpath={.status.publicDockerImageRepository}' )
oc adm release new \
  --from-release ${RELEASE_IMAGE_LATEST} \
  --to-image ${MIRROR_BASE}-scratch:release \
  --mirror ${MIRROR_BASE}-scratch \
  || echo 'ignore: the release could not be reproduced from its inputs'
oc adm release mirror \
  --from ${MIRROR_BASE}-scratch:release \
  --to ${MIRROR_BASE} \
  --to-release-image ${MIRROR_BASE}:mirrored
oc delete imagestream "$(basename "${MIRROR_BASE}-scratch")"

cat >> ${SHARED_DIR}/install-config.yaml << EOF
imageContentSources:
- source: "${MIRROR_BASE}-scratch"
  mirrors:
  - "${MIRROR_BASE}"
EOF
