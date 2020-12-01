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

export PATH=$PATH:"${SHARED_DIR}"
source "${SHARED_DIR}"/ovirt-event-functions.sh
installer_artifact_dir=${ARTIFACT_DIR}/installer

# Generate manifests first and force OpenShift SDN to be configured.
TF_LOG=debug openshift-install --dir="${installer_artifact_dir}" create manifests --log-level=debug &
wait "$!"
sed -i '/^  channel:/d' "${installer_artifact_dir}"/manifests/cvo-overrides.yaml

# This is for debugging purposes, allows us to map a job to a VM
cat "${installer_artifact_dir}"/manifests/cluster-infrastructure-02-config.yml

export KUBECONFIG="${installer_artifact_dir}"/auth/kubeconfig

#TODO: MOVE THIS TO THE FUNCTION
rchos_image=$(cat "${installer_artifact_dir}"/.openshift_install_state.json | /tmp/bin/jq '."*rhcos.Image"')

#notify oVirt infrastucture that ocp installation started
send_event_to_ovirt "Started"

TF_LOG=debug openshift-install --dir="${installer_artifact_dir}" create cluster --log-level=debug 2>&1 | grep --line-buffered -v password &
wait "$!"
install_exit_status=$?

# Password for the cluster gets leaked in the installer logs and hence removing them.
sed -i 's/password: .*/password: REDACTED"/g' "${installer_artifact_dir}"/.openshift_install.log

//Copy the auth artifacts to shared dir for the next steps
cp \
    -t "${SHARED_DIR}" \
    "${installer_artifact_dir}/auth/kubeconfig" \
    "${installer_artifact_dir}/auth/kubeadmin-password" \
    "${installer_artifact_dir}/metadata.json"

if test "${install_exit_status}" -eq 0 ; then
  send_event_to_ovirt "Success"
else
  send_event_to_ovirt "Failed"
fi

exit $install_exit_status

