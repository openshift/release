#!/bin/bash

set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# shellcheck source=/dev/null
source ${SHARED_DIR}/ovirt-lease.conf
# shellcheck source=/dev/null
source "${CLUSTER_PROFILE_DIR}/ovirt.conf"
# shellcheck source=/dev/null
source "${CLUSTER_PROFILE_DIR}/send-event-to-ovirt.sh"

installer_artifact_dir=/tmp/installer

mkdir ${installer_artifact_dir}

cp "${SHARED_DIR}"/* "${installer_artifact_dir}/"
(curl -L -o "${installer_artifact_dir}"/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 2>/dev/null && chmod +x "${installer_artifact_dir}"/jq)
if ! command -V "${installer_artifact_dir}"/jq; then
    echo "Failed to fetch jq"
    exit 1
fi
chmod ug+x "${installer_artifact_dir}"/jq
export PATH=$PATH:"${installer_artifact_dir}"

export OVIRT_CONFIG="${installer_artifact_dir}/ovirt-config.yaml"

if [[ ! -n $(echo "$JOB_NAME" | grep -P '\-upgrade\-') ]]; then
  echo "Using tmpfs hack for job $JOB_NAME"
  TF_LOG=debug openshift-install --dir="${installer_artifact_dir}" create ignition-configs --log-level=debug
  python -c \
      'import json, sys; j = json.load(sys.stdin); j[u"systemd"] = {}; j[u"systemd"][u"units"] = [{u"contents": "[Unit]\nDescription=Mount etcd as a ramdisk\nBefore=local-fs.target\n[Mount]\n What=none\nWhere=/var/lib/etcd\nType=tmpfs\nOptions=size=2G\n[Install]\nWantedBy=local-fs.target", u"enabled": True, u"name":u"var-lib-etcd.mount"}]; json.dump(j, sys.stdout)' \
      <"${installer_artifact_dir}/master.ign" \
      >"${installer_artifact_dir}/master.ign.out"
  mv "${installer_artifact_dir}/master.ign.out" "${installer_artifact_dir}/master.ign"
fi

# Generate manifests first and force OpenShift SDN to be configured.
TF_LOG=debug openshift-install --dir="${installer_artifact_dir}" create manifests --log-level=debug &
wait "$!"
sed -i '/^  channel:/d' "${installer_artifact_dir}"/manifests/cvo-overrides.yaml

# This is for debugging purposes, allows us to map a job to a VM
cat "${installer_artifact_dir}"/manifests/cluster-infrastructure-02-config.yml

export KUBECONFIG="${installer_artifact_dir}"/auth/kubeconfig

#notify oVirt infrastucture that ocp installation started
send_event_to_ovirt "Started"

TF_LOG=debug openshift-install --dir="${installer_artifact_dir}" create cluster --log-level=debug 2>&1 | grep --line-buffered -v password &
wait "$!"
install_exit_status=$?

# Password for the cluster gets leaked in the installer logs and hence removing them.
sed -i 's/password: .*/password: REDACTED"/g' "${installer_artifact_dir}"/.openshift_install.log

#Copy the auth artifacts to shared dir for the next steps
cp \
    -t "${SHARED_DIR}" \
    "${installer_artifact_dir}/auth/kubeconfig" \
    "${installer_artifact_dir}/auth/kubeadmin-password" \
    "${installer_artifact_dir}/metadata.json" \
    "${installer_artifact_dir}"/terraform.*

if test "${install_exit_status}" -eq 0 ; then
  send_event_to_ovirt "Success"
else
  send_event_to_ovirt "Failed"
fi

exit $install_exit_status

