#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="/tmp/install-config-mixed-publish.yaml.patch"
cluster_name=${NAMESPACE}-${UNIQUE_HASH}
base_domain="$(yq-go r ${CONFIG} 'baseDomain')"
no_proxy_list=""

if [[ -z "${APISERVER_PUBLISH_STRATEGY}" ]] && [[ -z "${INGRESS_PUBLISH_STRATEGY}" ]]; then
    echo "ERROR: Mixed publish setting, APISERVER_PUBLISH_STRATEGY and INGRESS_PUBLISH_STRATEGY are both empty!\nPlease specify the operator publishing strategy for mixed publish strategy!"
    exit 1
fi

cat > "${PATCH}" << EOF
publish: Mixed
operatorPublishingStrategy:
EOF

if [[ ! -z "${APISERVER_PUBLISH_STRATEGY}" ]]; then
cat >> "${PATCH}" << EOF
  apiserver: ${APISERVER_PUBLISH_STRATEGY}
EOF
    if [[ "${APISERVER_PUBLISH_STRATEGY}" == "External" ]]; then
        no_proxy_list="${no_proxy_list},api.${cluster_name}.${base_domain}"
    fi
fi

if [[ ! -z "${INGRESS_PUBLISH_STRATEGY}" ]]; then
cat >> "${PATCH}" << EOF
  ingress: ${INGRESS_PUBLISH_STRATEGY}
EOF
    if [[ "${INGRESS_PUBLISH_STRATEGY}" == "External" ]]; then
        no_proxy_list="${no_proxy_list},apps.${cluster_name}.${base_domain}"
    fi
fi

echo "APISERVER_PUBLISH_STRATEGY: ${APISERVER_PUBLISH_STRATEGY}"
echo "INGRESS_PUBLISH_STRATEGY: ${INGRESS_PUBLISH_STRATEGY}"
echo "The content of ${PATCH}:"
cat "${PATCH}"

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"

# add api/ingress fqdn into no_proxy when their publish strategy are External
if [[ -n "${no_proxy_list}" ]] && [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    sed -i "s/NO_PROXY=\"[^\"]*/&${no_proxy_list}/" "${SHARED_DIR}/proxy-conf.sh"
    sed -i "s/no_proxy=\"[^\"]*/&${no_proxy_list}/" "${SHARED_DIR}/proxy-conf.sh"
fi
