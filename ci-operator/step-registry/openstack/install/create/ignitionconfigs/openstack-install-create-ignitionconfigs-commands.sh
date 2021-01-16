#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp

#Do we really need this?
case "${CLUSTER_TYPE}" in
openstack) export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml ;;
openstack-vexxhost) export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
esac

dir=/tmp/installer
mkdir "${dir}/"
cp -R "${SHARED_DIR}/install-config.yaml" "${dir}/"


TF_LOG=debug openshift-install --dir="${dir}" create ignition-configs --log-level=debug 2>&1 | grep --line-buffered -v password &

set +e
wait "$!"
ret="$?"
cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
set -e

sed 's/password: .*/password: REDACTED/' "${dir}/.openshift_install.log" >"${ARTIFACT_DIR}/.openshift_install_create_ignition_configs.log"
cp \
    -t "${SHARED_DIR}" \
    "${dir}/auth/kubeconfig" \
    "${dir}/metadata.json" \
    "${dir}/*.ign" \
    "${dir}/.openshift*"
exit "$ret"
