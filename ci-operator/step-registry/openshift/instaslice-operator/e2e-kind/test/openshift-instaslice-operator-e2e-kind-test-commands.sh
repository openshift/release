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
ssh-keygen -t rsa -f "${HOME}"/.ssh/google_compute_engine -C "$(whoami)" -N ""
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

export IMG=quay.io/instaslice-operator/controller:test-e2e IMG_DMST=quay.io/instaslice-operator/daemonset:test-e2e

echo "Executing e2e tests on GCP VM: $VM_NAME"

gcloud compute ssh "$VM_NAME" --zone="$GOOGLE_COMPUTE_ZONE" --command="
set -eux
cd instaslice-operator
# deploy controller and daemonset using the locally built images
sed -i '/imagePullPolicy: Always/d' config/manager/manager.yaml
sed -i '/ImagePullPolicy: v1.PullAlways,/d' internal/controller/instaslice_controller.go
echo 'Building and loading container images locally'
export IMG=${IMG} IMG_DMST=${IMG_DMST}
IMG=${IMG} IMG_DMST=${IMG_DMST} make docker-build
# Load the images to kind cluster
kind load docker-image ${IMG}
kind load docker-image ${IMG_DMST}
echo 'Creating instaslice-system namespace'
kubectl create ns 'instaslice-system'
echo 'Installing instaslice CRD'
make install
sleep 10
make deploy
# Waiting for the controller-manager to be ready
kubectl wait --for=condition=ready pod -l control-plane=controller-manager -n instaslice-system --timeout=2m

echo 'Running the e2e tests'
export EMULATOR_MODE=false && go test ./test/e2e/ -v -ginkgo.v --timeout 20m
"
