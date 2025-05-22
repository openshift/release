#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Setting up GCP VM for Instaslice E2E..."
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

echo "🚀 Creating VM: $VM_NAME"

gcloud compute instances create "$VM_NAME" \
  --image-family="$IMAGE_FAMILY" \
  --image-project=${IMAGE_PROJECT} \
  --boot-disk-size=30GB \
  --machine-type=${MACHINE_TYPE} \
  --zone=${GOOGLE_COMPUTE_ZONE} \
  --maintenance-policy TERMINATE \
  --restart-on-failure

echo "Waiting for VM to become RUNNING..."
until [[ "$(gcloud compute instances describe "$VM_NAME" --zone="$GOOGLE_COMPUTE_ZONE" --format='get(status)')" == "RUNNING" ]]; do
  sleep 5
done

sleep 10
echo "Installing tools inside VM..."
# Install all the pre-reqs inside the GCP VM
gcloud compute ssh "$VM_NAME" --zone="$GOOGLE_COMPUTE_ZONE" --command='
  set -eux

  # Install Go and docker
  sudo snap install go --classic
  sudo apt update
  sudo apt install docker.io -y
  sudo usermod -aG docker $USER
  newgrp docker

  # Install kinD
  [ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-amd64
  chmod +x ./kind
  sudo mv ./kind /usr/local/bin/kind

  # Install helm
  wget https://get.helm.sh/helm-v3.17.2-linux-amd64.tar.gz
  tar -xvf helm-v3.17.2-linux-amd64.tar.gz
  sudo mv linux-amd64/helm /usr/local/bin/

  # Install kubectl, gcc, ginkgo, make, git
  sudo snap install kubectl  --classic
  sudo apt install gcc make git ginkgo skopeo -y

  # NVIDIA Driver Ubuntu installation
  sudo apt install linux-headers-$(uname -r) -y
  export distro=ubuntu2204 arch=x86_64 arch_ext=amd64
  wget https://developer.download.nvidia.com/compute/cuda/repos/$distro/$arch/cuda-keyring_1.1-1_all.deb
  sudo dpkg -i cuda-keyring_1.1-1_all.deb
  sudo apt update
  sudo apt install nvidia-open -y
  sudo apt install cuda-drivers -y
  #sudo reboot
'
echo "Rebooting the VM: $VM_NAME"
gcloud compute instances reset "$VM_NAME" --zone=$GOOGLE_COMPUTE_ZONE

# wait for the VM to be back in Running state
echo "Waiting for VM to become RUNNING..."
until [[ "$(gcloud compute instances describe "$VM_NAME" --zone="$GOOGLE_COMPUTE_ZONE" --format='get(status)')" == "RUNNING" ]]; do
  sleep 5
done

# Install nvidia container tool kit etc, enable the MIG mode on the GPU
gcloud compute ssh "$VM_NAME" --zone="$GOOGLE_COMPUTE_ZONE" --command='
set -eux
  # Install NVIDIA Container Toolkit
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" | \
      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  sudo sed -i -e "/experimental/ s/^#//g" /etc/apt/sources.list.d/nvidia-container-toolkit.list
  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit

  # Configure nvidia container runtime as a default runtime
  sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
  sudo systemctl restart docker
  sudo nvidia-ctk config --set accept-nvidia-visible-devices-as-volume-mounts=true --in-place

  # Enable MIG on the GPU
  nvidia-smi
  nvidia-smi -L
  sudo nvidia-smi -i 0 -mig 1
  # Verify the mig mode is enabled before triggering a reboot to avoid kernel panics

  # reset the GPU to enable the MIG
  # nvidia-smi --gpu-reset
  # nvidia-smi
'

echo "Rebooting the VM: $VM_NAME"
gcloud compute instances reset "$VM_NAME" --zone=$GOOGLE_COMPUTE_ZONE
# wait for the VM to be back in Running state
echo "Waiting for VM to become RUNNING..."
until [[ "$(gcloud compute instances describe "$VM_NAME" --zone="$GOOGLE_COMPUTE_ZONE" --format='get(status)')" == "RUNNING" ]]; do
  sleep 20
done

echo "GCP VM setup complete."
echo "Copying the instaslice operator"

echo $PWD
gcloud compute scp \
  --quiet \
  --project "${GOOGLE_COMPUTE_PROJECT}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse  /go/src/github.com/openshift/instaslice-operator "$VM_NAME":~/

gcloud compute ssh "$VM_NAME" --zone="$GOOGLE_COMPUTE_ZONE" --command="
set -eux
echo $PWD
cd ~/instaslice-operator
sed -i -e 's/docker exec -ti/docker exec -i/g' ./deploy/setup.sh
bash ./deploy/setup.sh
"