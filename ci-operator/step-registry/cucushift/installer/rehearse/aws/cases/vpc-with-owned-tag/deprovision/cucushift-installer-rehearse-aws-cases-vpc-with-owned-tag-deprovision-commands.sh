#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  CUSTOM_PAYLOAD_DIGEST=$(oc adm release info "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -a "${CLUSTER_PROFILE_DIR}/pull-secret" --output=jsonpath="{.digest}")
  CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE%:*}"@"$CUSTOM_PAYLOAD_DIGEST"
  echo "Overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} for cluster installation"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
  echo "Extracting installer from ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
  oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
  --command=openshift-install --to="/tmp" || exit 1
  export INSTALLER_BINARY="/tmp/openshift-install"
else
  export INSTALLER_BINARY="openshift-install"
fi

if [ -f "${SHARED_DIR}/cluster-1-metadata.json" ]; then
    echo "Destroying cluster 1"
    install_dir1=$(mktemp -d)
    cp "${SHARED_DIR}/cluster-1-metadata.json" ${install_dir1}/metadata.json
    ${INSTALLER_BINARY} destroy cluster --dir ${install_dir1}
fi

if [ -f "${SHARED_DIR}/cluster-2-metadata.json" ]; then
    echo "Destroying cluster 2"
    install_dir2=$(mktemp -d)
    cp "${SHARED_DIR}/cluster-2-metadata.json" ${install_dir2}/metadata.json
    ${INSTALLER_BINARY} destroy cluster --dir ${install_dir2}
fi
