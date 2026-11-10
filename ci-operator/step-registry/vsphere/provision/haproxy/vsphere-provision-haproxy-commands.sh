#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


mirror_registry_url=$(< "${SHARED_DIR}"/mirror_registry_url)

#Get haproxy-router image for upi disconnected installation
echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
target_release_image="${mirror_registry_url}/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"

haproxy_image_pullspec=$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" --image-for haproxy-router | awk -F'@' '{print $2}')
target_haproxy_image="${target_release_image_repo}@${haproxy_image_pullspec}"
echo "target haproxy image: ${target_haproxy_image}"

cat > "${SHARED_DIR}/haproxy-router-image" << EOF
${target_haproxy_image}
$(cat /var/run/vault/mirror-registry/registry_creds)
EOF
