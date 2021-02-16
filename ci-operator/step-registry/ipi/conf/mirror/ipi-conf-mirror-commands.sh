#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
mkdir -p ${HOME}/.docker
cp ${CLUSTER_PROFILE_DIR}/pull-secret ${HOME}/.docker/config.json
oc registry login
MIRROR_REPO=$( oc get is release -o 'jsonpath={.status.publicDockerImageRepository}' )
MIRROR_BASE=$(dirname ${REPO_NAME})
MIRROR_IMAGESTREAM="stable-mirrored"
oc adm release new \
  --from-release ${RELEASE_IMAGE_LATEST} \
  --to-image ${MIRROR_BASE}/${MIRROR_IMAGESTREAM}:release \
  --mirror ${MIRROR_BASE}/${MIRROR_IMAGESTREAM} \
  || echo 'ignore: the release could not be reproduced from its inputs'
oc adm release mirror \
  --from ${MIRROR_BASE}/${MIRROR_IMAGESTREAM}:release \
  --to ${MIRROR_REPO} \
  --to-release-image ${MIRROR_BASE}:mirrored
oc delete imagestream "$(basename "${MIRROR_BASE}/${MIRROR_IMAGESTREAM}")"

cat >> ${SHARED_DIR}/install-config.yaml << EOF
imageContentSources:
- source: "${MIRROR_BASE}/${MIRROR_IMAGESTREAM}"
  mirrors:
  - "${MIRROR_REPO}"
EOF
