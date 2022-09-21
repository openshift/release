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

mkdir -p "${HOME}"/.ssh
mock-nss.sh

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub
echo 'ServerAliveInterval 30' | tee -a "${HOME}"/.ssh/config
echo 'ServerAliveCountMax 1200' | tee -a "${HOME}"/.ssh/config
chmod 0600 "${HOME}"/.ssh/config

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

# GPC instance config script
export LD_PRELOAD=/usr/lib64/libnss_wrapper.so
cat <<EOF > "${PAYLOAD_PATH}"/usr/bin/pre_rpm_install.sh
#! /bin/bash
set -xeuo pipefail

rpm --rebuilddb
dnf install subscription-manager -y

subscription-manager register \
  --org="$(cat /var/run/rhsm/subscription-manager-org)" \
  --activationkey="$(cat /var/run/rhsm/subscription-manager-act-key)"
subscription-manager repos \
  --enable rhocp-4.10-for-rhel-8-x86_64-rpms \
  --enable fast-datapath-for-rhel-8-x86_64-rpms

dnf install jq firewalld -y
dnf install -y /packages/*.rpm
systemctl enable --now crio.service firewalld

firewall-cmd --zone=trusted --add-source=10.42.0.0/16 --permanent
firewall-cmd --zone=public --add-port=80/tcp --permanent
firewall-cmd --zone=public --add-port=443/tcp --permanent
firewall-cmd --zone=public --add-port=5353/udp --permanent
firewall-cmd --reload
EOF
chmod +x usr/bin/pre_rpm_install.sh
mkdir -p "${PAYLOAD_PATH}"/etc/crio/ && cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${PAYLOAD_PATH}"/etc/crio/openshift-pull-secret
chmod 600 "${PAYLOAD_PATH}"/etc/crio/openshift-pull-secret
tar -uvf $PAYLOAD_PATH/payload.tar .

gcloud compute scp "${PAYLOAD_PATH}/payload.tar" rhel8user@"${INSTANCE_PREFIX}":~
gcloud compute ssh rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo tar -xhvf $HOME/payload.tar -C / && \
             sudo pre_rpm_install.sh'