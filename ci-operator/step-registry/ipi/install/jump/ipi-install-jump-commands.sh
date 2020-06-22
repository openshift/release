#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp
export WORKSPACE=${WORKSPACE:-/tmp}
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

if [[ ! -s "${SHARED_DIR}/jump-host.txt" ]]
then
  echo "Missing jump host information in jump-host.txt"
  exit 1
fi

# This must match exactly to the ipi-install-install-commands.sh
cat >> ${WORKSPACE}/ipi-install-install-commands.sh << 'EOF'
#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi

export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp
export WORKSPACE=${WORKSPACE:-/tmp}
export PATH=${PATH}:${WORKSPACE}

case "${CLUSTER_TYPE}" in
aws) export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred;;
azure4) export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json;;
gcp) export GOOGLE_CLOUD_KEYFILE_JSON=${CLUSTER_PROFILE_DIR}/gce.json;;
vsphere) ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
esac

dir=${WORKSPACE}/installer
mkdir -p "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

openshift-install --dir="${dir}" create manifests &
wait "$!"

sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" -name "manifest_*.yml" -print0)

TF_LOG=debug openshift-install --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v password &

set +e
wait "$!"
ret="$?"
cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
set -e

sed 's/password: .*/password: REDACTED/' "${dir}/.openshift_install.log" >"${ARTIFACT_DIR}/.openshift_install.log"
cp \
    -t "${SHARED_DIR}" \
    "${dir}/auth/kubeconfig" \
    "${dir}/metadata.json"
exit "$ret"

EOF

run_rsync() {
  set -x
  rsync -PazcOq -e "ssh -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null -i ${SSH_PRIV_KEY_PATH}" "${@}"
  set +x
}

run_ssh() {
  set -x
  ssh -q -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null -i "${SSH_PRIV_KEY_PATH}" "${@}"
  set +x
}


REMOTE=$(<"${SHARED_DIR}/jump-host.txt") && export REMOTE
REMOTE_DIR="/tmp/install-$(date +%s%N)" && export REMOTE_DIR

if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

run_ssh "${REMOTE}" -- mkdir -p "${REMOTE_DIR}/cluster_profile" "${REMOTE_DIR}/shared_dir" "${REMOTE_DIR}/artifacts_dir"
cat >> ${WORKSPACE}/runner.env << EOF
export RELEASE_IMAGE_LATEST="${RELEASE_IMAGE_LATEST}"

export CLUSTER_TYPE="${CLUSTER_TYPE}"
export CLUSTER_PROFILE_DIR="${REMOTE_DIR}/cluster_profile"
export ARTIFACT_DIR="${REMOTE_DIR}/artifacts_dir"
export SHARED_DIR="${REMOTE_DIR}/shared_dir"
export KUBECONFIG="${REMOTE_DIR}/shared_dir/kubeconfig"

export JOB_NAME="${JOB_NAME}"
export BUILD_ID="${BUILD_ID}"

export WORKSPACE=${REMOTE_DIR}
EOF

run_rsync "$(which openshift-install)" ${WORKSPACE}/runner.env ${WORKSPACE}/ipi-install-install-commands.sh "${REMOTE}:${REMOTE_DIR}/"
run_rsync "${SHARED_DIR}/" "${REMOTE}:${REMOTE_DIR}/shared_dir/"
run_rsync "${CLUSTER_PROFILE_DIR}/" "${REMOTE}:${REMOTE_DIR}/cluster_profile/"

run_ssh "${REMOTE}" "source ${REMOTE_DIR}/runner.env && bash ${REMOTE_DIR}/ipi-install-install-commands.sh" &

set +e
wait "$!"
ret="$?"
set -e

run_rsync "${REMOTE}:${REMOTE_DIR}/shared_dir/" "${SHARED_DIR}/"
run_rsync --no-perms "${REMOTE}:${REMOTE_DIR}/artifacts_dir/" "${ARTIFACT_DIR}/"
run_ssh "${REMOTE}" "rm -rf ${REMOTE_DIR}"
exit "$ret"
