#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

buildfarm_secrets="/var/run/vault/secrets/.dockerconfigjson"

pull_secret=$(<"${buildfarm_secrets}")



# Add buildfarm secrets if the mirror registry secrets are not available.
if [ ! -f "${SHARED_DIR}/pull_secret_ca.yaml.patch" ]; then
  yq -i 'del(.pullSecret)' "${SHARED_DIR}/install-config.yaml"
  cat >>"${SHARED_DIR}/install-config.yaml" <<EOF
pullSecret: >
  ${pull_secret}
EOF
fi

# RELEASE_IMAGE_LATEST=registry.build06.ci.openshift.org/ci-op-3vpg3xwh/release@sha256:5591b23351d40563417fb22339dbf7125e5d4659752f5a2a6a44a355c9f1201a

# take the part before the first occurrence of '/', i.e. 'registry.build06.ci.openshift.org'
echo "${RELEASE_IMAGE_LATEST%%/*}" >> "${SHARED_DIR}/mirror_registry_url"

install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"

# take the part before the first occurrence of '@', i.e. 'registry.build06.ci.openshift.org/ci-op-3vpg3xwh/release'
imcs="
imageContentSources:
  - mirrors:
      - ${RELEASE_IMAGE_LATEST%%@*}
    source: ${RELEASE_IMAGE_LATEST%%@*}
  - mirrors:
      - ${RELEASE_IMAGE_LATEST%%@*}
    source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
"

echo "${imcs}" >> "${install_config_mirror_patch}"

CONFIG="${SHARED_DIR}/install-config.yaml"

# imageContentSources patch
yq-go m -x -i "${CONFIG}" "${install_config_mirror_patch}"