#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
random_num=$RANDOM

if [ -n "${BASE_DOMAIN}" ]; then
  new_base_domain="${BASE_DOMAIN}"
elif [[ $(( ${random_num} % 2 )) == 1 ]]; then
  new_base_domain="${random_num}test.${GCP_BASE_DOMAIN}"
else
  new_base_domain="${GCP_BASE_DOMAIN}"
fi

if [[ "${new_base_domain}" != "${GCP_BASE_DOMAIN}" ]]; then
  CONFIG="${SHARED_DIR}/install-config.yaml"
  PATCH="${SHARED_DIR}/install-config-patch.yaml"
  cat > "${PATCH}" << EOF
baseDomain: ${new_base_domain}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated baseDomain settings."
  yq-go r "${CONFIG}" baseDomain
fi