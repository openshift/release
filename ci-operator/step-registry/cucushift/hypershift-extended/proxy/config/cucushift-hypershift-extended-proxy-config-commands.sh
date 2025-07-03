#!/usr/bin/env bash

set -euo pipefail

proxy_private_url_file="${SHARED_DIR}/proxy_private_url"

if [ ! -f "${proxy_private_url_file}" ]; then
    echo "Did not found proxy setting from ${proxy_private_url_file}"
    exit 1
else
    PRIVATE_PROXY_URL=$(< "${proxy_private_url_file}")
fi

# Generate the main part of the patch.yaml
cat <<EOF > /tmp/patch.yaml
spec:
  configuration:
    proxy:
      httpProxy: $PRIVATE_PROXY_URL
      httpsProxy: $PRIVATE_PROXY_URL
EOF

echo "Patching rendered artifacts"
yq-v4 'select(.kind == "HostedCluster") *= load("/tmp/patch.yaml")' "${SHARED_DIR}"/hypershift_create_cluster_render.yaml \
    > "${SHARED_DIR}"/hypershift_create_cluster_render_proxy.yaml

echo "Applying patched artifacts"
oc apply -f "${SHARED_DIR}"/hypershift_create_cluster_render_proxy.yaml
