#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


mirror_registry_url=$(< "${SHARED_DIR}"/mirror_registry_url)

#Get haproxy-router image for upi disconnected installation
target_release_image="${mirror_registry_url}/${RELEASE_IMAGE_LATEST#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"

# shellcheck disable=SC2153
REPO=$(oc -n ${NAMESPACE} get is release -o json | jq -r '.status.publicDockerImageRepository')
haproxy_image_pullspec=$(oc adm release info "${REPO}:latest" --image-for haproxy-router | awk -F'@' '{print $2}')
target_haproxy_image="${target_release_image_repo}@${haproxy_image_pullspec}"
echo "target haproxy image: ${target_haproxy_image}"

cat > "${SHARED_DIR}/haproxy-router-image" << EOF
${target_haproxy_image}
$(cat /var/run/vault/mirror-registry/registry_creds)
EOF
