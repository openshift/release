#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq


if [ ! -f "${SHARED_DIR}/proxy_public_url" ]; then
  echo "Did not found proxy setting, \"proxy_public_url\" file is missing, abort"
  exit 1
fi

PROXY_URL=$(head -n 1 "${SHARED_DIR}/proxy_public_url")

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-proxy.yaml.patch"

echo "Patching Proxy settings to install-config.yaml"
cat > "${PATCH}" << EOF
proxy:
  httpsProxy: ${PROXY_URL}
  httpProxy: ${PROXY_URL}
EOF
/tmp/yq m -x -i "${CONFIG}" "${PATCH}"
