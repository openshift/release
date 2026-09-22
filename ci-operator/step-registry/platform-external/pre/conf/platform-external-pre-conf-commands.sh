#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#
# Enable CCM
#

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-external.yaml.patch
STEP_WORKDIR=${STEP_WORKDIR:-/tmp}
INSTALL_DIR=${STEP_WORKDIR}/install-dir
mkdir -vp "${INSTALL_DIR}"

source "${SHARED_DIR}/init-fn.sh" || true
install_yq4

#
# Append CI credentials to pull-secret (once, shared across later steps)
#
# Each multi-stage step runs in a new container, so /tmp is not shared.
# Write the enriched pull-secret under SHARED_DIR so manifests, CCM, and
# openshift-tests can reuse it without repeating `oc registry login`.
#
REGISTRY_AUTH_FILE="${REGISTRY_AUTH_FILE:-${SHARED_DIR}/pull-secret-with-ci}"
mkdir -p "$(dirname "${REGISTRY_AUTH_FILE}")"
cp -v "${CLUSTER_PROFILE_DIR}"/pull-secret "${REGISTRY_AUTH_FILE}"

if [[ $(dirname "$(dirname "${RELEASE_IMAGE_LATEST}" )") != "quay.io" ]]; then
  log "Logging to CI registry for later steps (extract/CCM/tests): $(dirname "$(dirname $RELEASE_IMAGE_LATEST )")"
  # Prefer build-cluster SA token over any SHARED_DIR kubeconfig.
  KUBECONFIG="" oc registry login --to "${REGISTRY_AUTH_FILE}"
fi

#
# Enable CCM
#
# Empty: act as None
# External: CCMO will wait for CCM to be installed at install time
export CONFIG_PLATFORM_EXTERNAL_CCM=""
if [[ "${PLATFORM_EXTERNAL_CCM_ENABLED-}" == "yes" ]]; then
  CONFIG_PLATFORM_EXTERNAL_CCM="External"
fi

# Setting the baseDomain from profile or leave the default.
#
if [[ -r "${CLUSTER_PROFILE_DIR}/baseDomain" ]]; then
  CLUSTER_BASE_DOMAIN=$(< ${CLUSTER_PROFILE_DIR}/baseDomain)
  echo "Using baseDomain from CI Profile, value: ${CLUSTER_BASE_DOMAIN}"
else
  CLUSTER_BASE_DOMAIN="${BASE_DOMAIN}"
  echo "Using baseDomain from default,value: ${BASE_DOMAIN}"
fi

#
# Patch the install-config.yaml
#
log "Creating install-config.yaml patch"
cat > "${PATCH}" << EOF
baseDomain: ${CLUSTER_BASE_DOMAIN}
platform:
  external:
    platformName: ${PROVIDER_NAME}
    cloudControllerManager: ${CONFIG_PLATFORM_EXTERNAL_CCM}
compute:
- name: worker
  replicas: 3
  architecture: amd64
controlPlane:
  name: master
  replicas: 3
  architecture: amd64
publish: External
pullSecret: '$(cat ${REGISTRY_AUTH_FILE} | awk -v ORS= -v OFS= '{$1=$1}1')'
EOF

log "Patching install-config.yaml"
yq4 eval-all --inplace '. as $item ireduce ({}; . *+ $item)' "${CONFIG}" "${PATCH}"

log "Reading install-config.yaml (withount credentials) and saving to artifacts path ${ARTIFACT_DIR}/install-config.yaml"
grep -v "password\|username\|pullSecret\|{\"auths\":{\|httpProxy\|httpsProxy" "${CONFIG}" | tee "${ARTIFACT_DIR}"/install-config.yaml || true
