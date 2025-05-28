#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ openshift cert rotation assisted on gcp command ************"

INSTANCE_PREFIX="${NAMESPACE}"-"${UNIQUE_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Configuring VM on GCP..."
export HOME=/tmp
mkdir -p "${HOME}"/.ssh
mock-nss.sh

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" "${HOME}/.ssh/google_compute_engine"
chmod 0600 "${HOME}/.ssh/google_compute_engine"
cp "${CLUSTER_PROFILE_DIR}/ssh-publickey" "${HOME}/.ssh/google_compute_engine.pub"

SSHOPTS=(-o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o LogLevel=ERROR -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")
IP=$(gcloud compute \
    instances describe ${INSTANCE_PREFIX} \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)' \
    --zone "${GOOGLE_COMPUTE_ZONE}" \
    --project "${GOOGLE_PROJECT_ID}")
echo ${IP} > ${SHARED_DIR}/server-ip

cat > ${SHARED_DIR}/packet-conf.sh <<-EOF
source "${SHARED_DIR}/fix-uid.sh"
export IP=$(cat "${SHARED_DIR}/server-ip")
export SSH_KEY_FILE=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export SSHOPTS=(${SSHOPTS[@]})
EOF

cp -rvf ${SHARED_DIR}/packet-conf.sh ${SHARED_DIR}/ci-machine-config.sh

cat > ${SHARED_DIR}/fix-uid.sh <<-EOF
# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [ -x "$(command -v nss_wrapper.pl)" ]; then
        grep -v -e ^default -e ^$(id -u) /etc/passwd > "/tmp/passwd"
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> "/tmp/passwd"
        export LD_PRELOAD=libnss_wrapper.so
        export NSS_WRAPPER_PASSWD=/tmp/passwd
        export NSS_WRAPPER_GROUP=/etc/group
    elif [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> "/etc/passwd"
    else
        echo "No nss wrapper, /etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi
EOF

# Prepare login via root
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
    --zone "${GOOGLE_COMPUTE_ZONE}" \
    packer@"${INSTANCE_PREFIX}" \
    --command "sudo cp ~/.ssh/authorized_keys /root/.ssh && sudo sed 's;PermitRootLogin no;PermitRootLogin yes;g' -i /etc/ssh/sshd_config && sudo systemctl restart sshd"

# Enable the Codeready Builder repository
ssh "${SSHOPTS[@]}" "root@${IP}" \
    dnf config-manager --set-enabled rhui-codeready-builder-for-rhel-9-x86_64-rhui-rpms

# Remove KUBECONFIG env var from /etc/bash set by packer
ssh "${SSHOPTS[@]}" "root@${IP}" \
    sed -i '/KUBECONFIG/d' /etc/bashrc
