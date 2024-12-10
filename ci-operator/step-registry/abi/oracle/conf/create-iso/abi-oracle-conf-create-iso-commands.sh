#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
INSTALL_DIR="${INSTALL_DIR:-/tmp/installer}"
MANIFESTS_DIR="${INSTALL_DIR}/openshift"

mkdir -p "${INSTALL_DIR}"
# CCM/CSI manifests for OCI go in openshift/
mkdir -p "${MANIFESTS_DIR}"


function oinst() {
  /tmp/openshift-install --dir="${INSTALL_DIR}" --log-level=debug "${@}" 2>&1 | grep\
   --line-buffered -v 'password\|X-Auth-Token\|UserData:'
}

cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"
cp "${SHARED_DIR}/agent-config.yaml" "${INSTALL_DIR}/"

# From now on, we assume no more patches to the install-config.yaml are needed.
# Also, we assume that the agent-config.yaml is already in place in the SHARED_DIR.
# We can create the installation dir with the install-config.yaml and agent-config.yaml.
grep -v "password\|username\|pullSecret" "${SHARED_DIR}/install-config.yaml" > "${ARTIFACT_DIR}/install-config.yaml" || true
grep -v "password\|username\|pullSecret" "${SHARED_DIR}/agent-config.yaml" > "${ARTIFACT_DIR}/agent-config.yaml" || true

echo "Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
oc adm release extract -a "$PULL_SECRET_PATH" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
   --command=openshift-install --to=/tmp

echo "Downloading mhanss terraform files"

SOURCE_DIR="${SHARED_DIR}/oci-openshift"

mkdir -p $SOURCE_DIR

git clone https://github.com/mhanss/oci-openshift.git $SOURCE_DIR

cd $SOURCE_DIR

echo "Using abi-on-oci branch"

git switch abi-on-oci

cp -R $SOURCE_DIR/custom_manifests/manifests/ $MANIFESTS_DIR

### Create ISO image
echo -e "\nCreating image..."
oinst agent create image