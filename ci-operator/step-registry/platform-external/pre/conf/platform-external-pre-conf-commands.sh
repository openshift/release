#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Using release image ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

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
# Append CI credentials to pull-secret
#
log "Logging to CI registry: $(dirname "$(dirname $RELEASE_IMAGE_LATEST )")"
export PULL_SECRET=/tmp/pull-secret-with-ci
cp -v "${CLUSTER_PROFILE_DIR}"/pull-secret $PULL_SECRET
oc registry login --to $PULL_SECRET

log "Saving CI pull secret to extract image info to CI registry: "
cp -v ${PULL_SECRET} "${SHARED_DIR}/pull-secret-with-ci"

#
# Enable CCM
#
# Empty: act as None
# External: CCMO will wait for CCM to be installed at install time
export CONFIG_PLATFORM_EXTERNAL_CCM=""
if [[ "${PLATFORM_EXTERNAL_CCM_ENABLED-}" == "yes" ]]; then
  CONFIG_PLATFORM_EXTERNAL_CCM="External"
fi

#
# Render the install-config.yaml
#
log "Creating install-config.yaml patch"
cat > "${PATCH}" << EOF
baseDomain: ${BASE_DOMAIN}
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
pullSecret: '$(cat ${PULL_SECRET} | awk -v ORS= -v OFS= '{$1=$1}1')'
EOF

log "Patching install-config.yaml"
yq4 eval-all --inplace '. as $item ireduce ({}; . *+ $item)' "${CONFIG}" "${PATCH}"

log "Reading install-config.yaml (withount credentials) and saving to artifacts path ${ARTIFACT_DIR}/install-config.yaml"
grep -v "password\|username\|pullSecret\|{\"auths\":{" "${CONFIG}" | tee "${ARTIFACT_DIR}"/install-config.yaml || true
