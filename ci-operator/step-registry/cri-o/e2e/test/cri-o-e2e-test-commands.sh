#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "entering setup!!!!"
source "${SHARED_DIR}/env"

#####################################
###############Log In################
#####################################

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

mkdir -p "${HOME}"/.ssh
chmod 0700 "${HOME}"/.ssh

cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub

#####################################
#####################################

instance_name=$(<"${SHARED_DIR}/gcp-instance-ids.txt")

tar -czf - . | gcloud compute ssh --zone="${ZONE}" ${instance_name} -- "cat > ~/cri-o.tar.gz"
timeout --kill-after 10m 400m gcloud compute ssh --zone="${ZONE}" ${instance_name} -- bash - << EOF 
    mkdir -p /tmp/artifacts/logs
    mkdir -p /logs/artifacts
    sudo dnf install python39 -y
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    python3.9 get-pip.py
    python3.9 -m pip install ansible
    # setup the directory where the tests will the run
    REPO_DIR="~/cri-o"
    mkdir -p "\${REPO_DIR}"
    # NVMe makes it faster
    NVME_DEVICE="/dev/nvme0n1"
    if [ -e "\$NVME_DEVICE" ];
    then
        mkfs.xfs -f "\${NVME_DEVICE}"
        mount "\${NVME_DEVICE}" "\${REPO_DIR}"
    fi
    # copy the agent sources on the remote machine
    tar -xzvf cri-o.tar.gz -C "\${REPO_DIR}"
    chown -R root:root "\${REPO_DIR}"
    cd "\${REPO_DIR}/contrib/test/ci"
    echo "localhost" >> hosts
    ansible-playbook e2e-main.yml -i hosts -e "TEST_AGENT=prow" --connection=local -vvv --tags setup,e2e
EOF
