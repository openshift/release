#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# implement rendezvous ip logic in jinja template rendezvousIP: {{ hosts[0].ip }}

#export RENDEZVOUS_IP="$(yq -r e -o=j -I=0 ".[0].ip" "${SHARED_DIR}/hosts.yaml")"

INSTALL_DIR="/tmp/installer"
mkdir -p "${INSTALL_DIR}"
git clone -b master https://github.com/openshift-qe/agent-qe.git "${INSTALL_DIR}/agent-qe"

pip install j2cli



INVENTORY="${INSTALL_DIR}/agent-install-inventory.yaml"

echo "$(echo -en 'hosts:\n'; cat "${SHARED_DIR}/hosts.yaml")" > "${INVENTORY}"

cp "${INVENTORY}" "${ARTIFACT_DIR}/"

AGENT_CONFIG_YAML_FILENAME="agent-config.yaml"

if [ "${UNCONFIGURED_INSTALL}" == "true" ]; then
    AGENT_CONFIG_YAML_FILENAME="unconfigured-agent-config.yaml"
fi

/alabama/.local/bin/j2 "${INSTALL_DIR}/agent-qe/prow-utils/templates/agent-config.yaml.j2" "${INVENTORY}" -o "${ARTIFACT_DIR}/${AGENT_CONFIG_YAML_FILENAME}" 

cp "${ARTIFACT_DIR}/${AGENT_CONFIG_YAML_FILENAME}" "${SHARED_DIR}/"