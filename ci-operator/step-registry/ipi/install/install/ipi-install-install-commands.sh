#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
export SSH_PRIV_KEY_PATH=${cluster_profile}/ssh-privatekey
export PULL_SECRET_PATH=${cluster_profile}/pull-secret
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}
export HOME=/tmp

case "${CLUSTER_TYPE}" in
aws) export AWS_SHARED_CREDENTIALS_FILE=${cluster_profile}/.awscred;;
azure4) export AZURE_AUTH_LOCATION=${cluster_profile}/osServicePrincipal.json;;
gcp) export GOOGLE_CLOUD_KEYFILE_JSON=${cluster_profile}/gce.json;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
esac

dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

# TODO RELEASE_IMAGE_INITIAL / upgrade tests
# TODO mirror variant
# TODO manual override

TF_LOG=debug openshift-install --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v password &

set +e
wait "$!"
ret=$?
set -e

mkdir /tmp/secret
cp \
    -t /tmp/secret \
    "${dir}/auth/kubeconfig" \
    "${dir}/metadata.json" \
    "${dir}/terraform.tfstate"
cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/"
exit "$ret"
