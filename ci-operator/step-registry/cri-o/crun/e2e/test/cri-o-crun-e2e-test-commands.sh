#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
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

tar -czf - . | gcloud compute ssh --zone="${ZONE}" ${instance_name} -- "cat > \${HOME}/cri-o.tar.gz"
timeout --kill-after 10m 400m gcloud compute ssh --zone="${ZONE}" ${instance_name} -- bash - << EOF 
    export GOROOT=/usr/local/go
    echo GOROOT="/usr/local/go" | sudo tee -a /etc/environment
    mkdir -p \${HOME}/logs/artifacts
    mkdir -p /tmp/artifacts/logs

    sudo dnf install python39 -y
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    python3.9 get-pip.py
    python3.9 -m pip install ansible

    # setup the directory where the tests will the run
    REPO_DIR="/home/deadbeef/cri-o"
    mkdir -p "\${REPO_DIR}"
    # copy the agent sources on the remote machine
    tar -xzf cri-o.tar.gz -C "\${REPO_DIR}"
    cd "\${REPO_DIR}/contrib/test/ci"
    echo "localhost" >> hosts
    ansible-playbook e2e-main.yml -i hosts -e "TEST_AGENT=prow" --connection=local -vvv --tags setup,e2e --extra-vars "build_runc=False build_crun=True"
    sudo chown -R deadbeef /tmp/artifacts/*
    sudo chmod -R 777 /tmp/artifacts/*
EOF
