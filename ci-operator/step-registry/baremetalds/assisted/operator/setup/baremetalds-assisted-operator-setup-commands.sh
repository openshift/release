#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

git clone https://github.com/openshift/assisted-service
cd assisted-service/
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

REPO_DIR="/home/assisted-service"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "\${REPO_DIR}"
fi

cd "\${REPO_DIR}"

export DISCONNECTED="${DISCONNECTED:-}"

if [ "\${DISCONNECTED}" = "true" ]; then
  export LOCAL_REGISTRY="\${LOCAL_REGISTRY_DNS_NAME}:\${LOCAL_REGISTRY_PORT}"

  source deploy/operator/mirror_utils.sh

  export AUTHFILE="\${XDG_RUNTIME_DIR}/containers/auth.json"
  mkdir -p \$(dirname \${AUTHFILE})

  merge_authfiles "\${PULL_SECRET_FILE}" "\${REGISTRY_CREDS}" "\${AUTHFILE}"
fi

echo "### Setup hive..."

if [ "\${DISCONNECTED}" = "true" ]; then
  hack/setup_env.sh hive_from_upstream
  deploy/operator/setup_hive.sh from_upstream
else
  deploy/operator/setup_hive.sh with_olm
fi

export OPENSHIFT_VERSIONS=\$(cat data/default_ocp_versions.json |
  jq -rc 'with_entries(.key = "4.8") | with_entries(
      {key: .key, value: {rhcos_image: .value.rhcos_image,
      rhcos_version: .value.rhcos_version,
      rhcos_rootfs: .value.rhcos_rootfs}})')

if [ "\${DISCONNECTED}" = "true" ]; then
  echo "### Mirroring RHCOS and Rootfs images..."
  rhcos_image=\$(echo \${OPENSHIFT_VERSIONS} | jq -r '.[].rhcos_image')
  rhcos_rootfs=\$(echo \${OPENSHIFT_VERSIONS} | jq -r '.[].rhcos_rootfs')

  assisted_images_dir="\${IRONIC_IMAGES_DIR}/assisted"
  mkdir -p "\${assisted_images_dir}"
  curl --retry 5 "\${rhcos_image}" -o "\${assisted_images_dir}/\${rhcos_image##*/}"
  curl --retry 5 "\${rhcos_rootfs}" -o "\${assisted_images_dir}/\${rhcos_rootfs##*/}"

  images_base_url="http://\$(wrap_if_ipv6 \${PROVISIONING_HOST_IP})/images/assisted"
  rhcos_image="\${images_base_url}/\${rhcos_image##*/}"
  rhcos_rootfs="\${images_base_url}/\${rhcos_rootfs##*/}"

  OPENSHIFT_VERSIONS=\$(echo \$OPENSHIFT_VERSIONS |
      jq ".[].rhcos_image=\"\${rhcos_image}\" | .[].rhcos_rootfs=\"\${rhcos_rootfs}\"")
fi

echo "### Setup assisted installer..."
export INDEX_IMAGE="\$(dirname ${INDEX_IMAGE})/pipeline:ci-index"
export OPENSHIFT_VERSIONS=\$(cat data/default_ocp_versions.json |
    jq -rc 'with_entries(.key = "4.8") | with_entries(
      {
        key: .key,
        value: {rhcos_image:   .value.rhcos_image,
                rhcos_version: .value.rhcos_version,
                rhcos_rootfs:  .value.rhcos_rootfs}
      }
    )')

images=(${ASSISTED_AGENT_IMAGE} ${ASSISTED_CONTROLLER_IMAGE} ${ASSISTED_INSTALLER_IMAGE})
export PUBLIC_CONTAINER_REGISTRIES=\$(for image in \${images}; do echo \${image} | cut -d'/' -f1; done | sort -u | paste -sd "," -)
deploy/operator/setup_assisted_operator.sh

EOF
