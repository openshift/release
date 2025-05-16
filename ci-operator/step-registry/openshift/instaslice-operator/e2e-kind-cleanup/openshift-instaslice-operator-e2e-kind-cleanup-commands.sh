#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_PROFILE_DIR="/run/secrets/ci.openshift.io/cluster-profile"
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json

VM_NAME="prow-e2e-vm-${PROW_JOB_ID}"
GOOGLE_COMPUTE_ZONE="us-central1-f"
GOOGLE_COMPUTE_REGION="us-central1"
MACHINE_TYPE="a2-highgpu-1g"
IMAGE_FAMILY="ubuntu-2204-lts"
IMAGE_PROJECT="ubuntu-os-cloud"
GOOGLE_COMPUTE_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"

mkdir -p "${HOME}"/.ssh
chmod 0700 "${HOME}"/.ssh

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub
echo 'ServerAliveInterval 30' | tee -a "${HOME}"/.ssh/config
echo 'ServerAliveCountMax 1200' | tee -a "${HOME}"/.ssh/config
chmod 0600 "${HOME}"/.ssh/config

echo "Authenticating with GCP"
pushd /tmp
curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-318.0.0-linux-x86_64.tar.gz
tar -xzf google-cloud-sdk-318.0.0-linux-x86_64.tar.gz
export PATH=$PATH:/tmp/google-cloud-sdk/bin
mkdir gcloudconfig
export CLOUDSDK_CONFIG=/tmp/gcloudconfig
gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud config set project "${GOOGLE_COMPUTE_PROJECT}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"
popd

# Optional: clean up to avoid charges
echo "Cleaning up VM..."
gcloud compute instances delete "$VM_NAME" --zone="$GOOGLE_COMPUTE_ZONE" --quiet
