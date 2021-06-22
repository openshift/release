#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

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

echo "### Setup hive..."

if [ "\${DISCONNECTED}" = "true" ]; then
  export LOCAL_REGISTRY="\${LOCAL_REGISTRY_DNS_NAME}:\${LOCAL_REGISTRY_PORT}"

  source deploy/operator/mirror_utils.sh

  export AUTHFILE="\${XDG_RUNTIME_DIR}/containers/auth.json"
  mkdir -p \$(dirname \${AUTHFILE})

  merge_authfiles "\${PULL_SECRET_FILE}" "\${REGISTRY_CREDS}" "\${AUTHFILE}"
  hack/setup_env.sh hive_from_upstream
  deploy/operator/setup_hive.sh from_upstream
else
  deploy/operator/setup_hive.sh with_olm
fi

echo "### Setup assisted installer..."

# TODO: remove this and support mirroring an index referenced by digest value
# https://issues.redhat.com/browse/MGMT-6858
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

if [ "\${DISCONNECTED}" = "true" ]; then
  export MIRROR_BASE_URL="http://\$(wrap_if_ipv6 \${PROVISIONING_HOST_IP})/images"
  export IRONIC_IMAGES_DIR
fi

images=(${ASSISTED_AGENT_IMAGE} ${ASSISTED_CONTROLLER_IMAGE} ${ASSISTED_INSTALLER_IMAGE})
export PUBLIC_CONTAINER_REGISTRIES=\$(for image in \${images}; do echo \${image} | cut -d'/' -f1; done | sort -u | paste -sd "," -)

deploy/operator/setup_assisted_operator.sh

EOF
