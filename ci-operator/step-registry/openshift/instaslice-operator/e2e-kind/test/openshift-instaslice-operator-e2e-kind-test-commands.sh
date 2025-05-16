#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_PROFILE_DIR="/run/secrets/ci.openshift.io/cluster-profile"
export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
VM_NAME="prow-e2e-vm-${PROW_JOB_ID}"
GOOGLE_COMPUTE_ZONE="us-central1-f"
GOOGLE_COMPUTE_REGION="us-central1"
GOOGLE_COMPUTE_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"

mkdir -p "${HOME}"/.ssh
chmod 0700 "${HOME}"/.ssh
ssh-keygen -t rsa -f "${HOME}"/.ssh/google_compute_engine -C $(whoami) -N ""
chmod 0600 "${HOME}"/.ssh/google_compute_engine
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

export BUNDLE_IMG=quay.io/redhat-user-workloads/dynamicacceleratorsl-tenant/instaslice-operator-bundle:on-pr-${PULL_NUMBER}
echo "Executing e2e tests on GCP VM: $VM_NAME"
gcloud compute ssh "$VM_NAME" --zone="$GOOGLE_COMPUTE_ZONE" --command="
set -eux
cd instaslice-operator

# Install tools
mkdir -p /tmp/bin
export PATH=/tmp/bin:$${PATH}

echo '## Install umoci'
curl -L --retry 5 https://github.com/opencontainers/umoci/releases/download/v0.4.7/umoci.amd64 -o /tmp/bin/umoci && chmod +x /tmp/bin/umoci
echo '   umoci installed'

echo 'Waiting for image ${BUNDLE_IMG} to be available...'
function wait_for_image() {
    until skopeo inspect docker://${BUNDLE_IMG} >/dev/null 2>&1; do
        echo 'Image not found yet. Retrying in 30s...'
        sleep 30
    done
}

export -f wait_for_image
timeout 25m bash -c 'wait_for_image'

echo 'Image is available. Proceeding with tests...'

mkdir /tmp/oci-image && pushd /tmp/oci-image
skopeo copy docker://${BUNDLE_IMG} oci:instaslice-operator-bundle:pr
umoci unpack --rootless --image ./instaslice-operator-bundle:pr bundle/
kubectl create -f bundle/rootfs/manifests
popd

make test-e2e
"
