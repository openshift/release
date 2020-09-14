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

# This must match exactly to the ipi-deprovision-deprovision-commands.sh
cat >> ${WORKSPACE}/ipi-deprovision-deprovision-commands.sh << 'EOF'
#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE=$CLUSTER_PROFILE_DIR/.awscred
export AZURE_AUTH_LOCATION=$CLUSTER_PROFILE_DIR/osServicePrincipal.json
export GOOGLE_CLOUD_KEYFILE_JSON=$CLUSTER_PROFILE_DIR/gce.json
export HOME=/tmp
export WORKSPACE=${WORKSPACE:-/tmp}
export PATH=${PATH}:${WORKSPACE}

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

dir=${WORKSPACE}/installer
mkdir -p "${dir}/"
cp -ar "${SHARED_DIR}"/* "${dir}/"
openshift-install --dir "${dir}" destroy cluster &

set +e
wait "$!"
ret="$?"
set -e

cp "${dir}"/.openshift_install.log "${ARTIFACT_DIR}"

exit "$ret"

EOF

run_rsync() {
  set -x
  rsync -PazcO -e "ssh -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null -i ${SSH_PRIV_KEY_PATH}" "${@}"
  set +x
}

run_ssh() {
  set -x
  ssh -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null -i "${SSH_PRIV_KEY_PATH}" "${@}"
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

run_rsync "$(which openshift-install)" ${WORKSPACE}/runner.env ${WORKSPACE}/ipi-deprovision-deprovision-commands.sh "${REMOTE}:${REMOTE_DIR}/"
run_rsync "${SHARED_DIR}/" "${REMOTE}:${REMOTE_DIR}/shared_dir/"
run_rsync "${CLUSTER_PROFILE_DIR}/" "${REMOTE}:${REMOTE_DIR}/cluster_profile/"

run_ssh "${REMOTE}" "source ${REMOTE_DIR}/runner.env && bash ${REMOTE_DIR}/ipi-deprovision-deprovision-commands.sh" &

set +e
wait "$!"
ret="$?"
set -e

run_rsync "${REMOTE}:${REMOTE_DIR}/shared_dir/" "${SHARED_DIR}/"
run_rsync --no-perms "${REMOTE}:${REMOTE_DIR}/artifacts_dir/" "${ARTIFACT_DIR}/"
run_ssh "${REMOTE}" "rm -rf ${REMOTE_DIR}"
exit "$ret"
