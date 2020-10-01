#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail



#if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
#  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
#  exit 1
#fi
#
#echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
#export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
# DO WE NEED THE 6 lines above for this? lets comment them out for now.

export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml
dir=/tmp/installer
mkdir -p "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

TF_LOG=debug  openshift-install --dir="${dir}" create manifests --log-level debug &
wait "$!"


TF_LOG=debug  openshift-install --dir="${dir}" create ignition-configs --log-level debug &

wait "$!"