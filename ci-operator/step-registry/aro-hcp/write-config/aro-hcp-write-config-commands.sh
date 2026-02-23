#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LOCATION:-}" ]]; then
  export LOCATION="${MULTISTAGE_PARAM_OVERRIDE_LOCATION}"
fi


# NOTE: this config will be only partially accurate on public envs
make -C config render-partial-config \
  ARO_HCP_CLOUD="${ARO_HCP_CLOUD}" \
  ARO_HCP_DEPLOY_ENV="${ARO_HCP_DEPLOY_ENV}" \
  LOCATION="${LOCATION}" \
  STAMP=1 \
  CONFIG_OUTPUT="${SHARED_DIR}/config.yaml"

cp "${SHARED_DIR}/config.yaml" "${ARTIFACT_DIR}/config.yaml"
