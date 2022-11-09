#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"

#####################################
###############Log In################
#####################################

python3 --version 

export CLOUDSDK_PYTHON=python3 

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

timeout --kill-after 10m 400m gcloud compute ssh --zone="${ZONE}" ${instance_name} -- bash - << EOF 
    REPO_DIR="/home/deadbeef/cri-o"
    cd "\${REPO_DIR}/contrib/test/ci"
    ansible-playbook setup-main.yml --connection=local -vvv
EOF

currentDate=$(date +'%s')
gcloud compute instances stop ${instance_name} --zone=${ZONE} 
gcloud compute images create crio-setup-fedora-${currentDate} --source-disk-zone=${ZONE} --source-disk="${instance_name//[$'\t\r\n']}" --family="crio-setup-fedora"

