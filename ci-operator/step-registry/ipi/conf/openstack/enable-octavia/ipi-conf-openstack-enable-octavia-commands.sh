#!/usr/bin/env bash

set -euo pipefail

if [[ "$NETWORK_TYPE" == "Kuryr" ]]; then
    echo "Cloud provider load-balancer support shouldn't be enabled with $NETWORK_TYPE"
    exit 0
fi

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

# Create temporary directory
TMP_DIR=$(mktemp -d)

cp "${SHARED_DIR}/install-config.yaml" ${TMP_DIR}

# Create manifests
echo "Creating manifests"
openshift-install create manifests --dir ${TMP_DIR}

# Extract current cloud.conf
yq -r .data.config ${TMP_DIR}/manifests/cloud-provider-config.yaml > ${TMP_DIR}/cloud.conf

# Delete the LoadBalancer section if it exists
sed -i '/^\[LoadBalancer\]/,/^\[/{/^\[/!d}' ${TMP_DIR}/cloud.conf
sed -i '/^\[LoadBalancer\]/d' ${TMP_DIR}/cloud.conf

cat << EOF >> ${TMP_DIR}/cloud.conf
[LoadBalancer]
lb-provider=amphora
# The following settings are necessary for creating services with externalTrafficPolicy: Local
# NOT compatible with lb-provider=ovn
# create-monitor=true
# monitor-delay=5s
# monitor-timeout=3s
# monitor-max-retries=1
EOF

# We're only getting jq v1.5 in this image that doesn't support the `--rawfile` option.
# Once we get jq 1.6, we'll be able to simplify to:
# yq -Y --rawfile config ${TMP_DIR}/cloud.conf '.data.config |= $config' \
#         ${TMP_DIR}/manifests/cloud-provider-config.yaml > ${SHARED_DIR}/manifest_cloud-provider-config.yaml
yq -Y --argfile config <(jq -Rs '{config: .}' ${TMP_DIR}/cloud.conf) '.data.config |= $config.config' \
        ${TMP_DIR}/manifests/cloud-provider-config.yaml > ${SHARED_DIR}/manifest_cloud-provider-config.yaml

echo "Manifest was created with content:"
cat ${SHARED_DIR}/manifest_cloud-provider-config.yaml
