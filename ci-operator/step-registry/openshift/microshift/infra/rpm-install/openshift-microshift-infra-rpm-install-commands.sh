#!/bin/bash
set -euox pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

IP_ADDRESS="$(gcloud compute instances describe ${INSTANCE_PREFIX} --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"

mkdir -p "${HOME}"/.ssh
cat << EOF > "${HOME}"/.ssh/config
Host ${INSTANCE_PREFIX}
  User rhel8user
  HostName ${IP_ADDRESS}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
EOF
chmod 0600 "${HOME}"/.ssh/config

cat <<EOF > "${PAYLOAD_PATH}"/usr/bin/pre_rpm_install.sh
#! /bin/bash
set -xeuo pipefail

rpm --rebuilddb
dnf install subscription-manager -y

subscription-manager register \
  --org="$(cat /var/run/rhsm/subscription-manager-org)" \
  --activationkey="$(cat /var/run/rhsm/subscription-manager-act-key)"

sed -i '2i set -x' /usr/bin/configure-vm.sh

sudo useradd -m -G wheel microshift
sudo echo -e 'microshift\tALL=(ALL)\tNOPASSWD: ALL' > /etc/sudoers.d/microshift
cd /home/microshift && sudo -nu microshift configure-vm.sh --no-build /etc/crio/openshift-pull-secret

dnf install jq firewalld -y
dnf localinstall -y \$(find /packages/ -iname "*\$(uname -p)*" -or -iname '*noarch*')
EOF
chmod +x usr/bin/pre_rpm_install.sh

mkdir -p "${PAYLOAD_PATH}"/etc/microshift
IP_ADDRESS="$(gcloud compute instances describe ${INSTANCE_PREFIX} --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
cat << EOF > "${PAYLOAD_PATH}"/etc/microshift/config.yaml
---
apiServer:
  subjectAltNames:
  - ${IP_ADDRESS}
EOF

mkdir -p "${PAYLOAD_PATH}"/etc/crio/ && cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${PAYLOAD_PATH}"/etc/crio/openshift-pull-secret
chmod 600 "${PAYLOAD_PATH}"/etc/crio/openshift-pull-secret
tar -uvf $PAYLOAD_PATH/payload.tar .

scp "${PAYLOAD_PATH}/payload.tar" "${INSTANCE_PREFIX}":~
ssh "${INSTANCE_PREFIX}" \
  'sudo tar -xhvf $HOME/payload.tar -C / && \
   sudo pre_rpm_install.sh'

gcloud compute firewall-rules update "${INSTANCE_PREFIX}" --allow tcp:22,icmp,tcp:80,tcp:443,tcp:6443
