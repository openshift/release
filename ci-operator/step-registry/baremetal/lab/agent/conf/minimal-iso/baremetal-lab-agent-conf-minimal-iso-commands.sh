#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating patch file to configure minimal iso: ${SHARED_DIR}/minimal_iso_patch_agent_config.yaml"

if [[ "${MINIMAL_ISO:-false}" == "true" ]]; then
  cat > "${SHARED_DIR}/minimal_iso_patch_agent_config.yaml" <<EOF
minimalISO: ${MINIMAL_ISO}
bootArtifactsBaseURL: http://${AUX_HOST}
EOF
fi