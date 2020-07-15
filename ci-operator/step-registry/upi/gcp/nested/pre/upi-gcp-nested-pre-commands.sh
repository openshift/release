#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}-${JOB_NAME_HASH}"

echo "$(date -u --rfc-3339=seconds) - Configuring VM on GCP..."
mkdir -p "${HOME}"/.ssh
mock-nss.sh

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" "${HOME}/.ssh/google_compute_engine"
chmod 0600 "${HOME}/.ssh/google_compute_engine"
cp "${CLUSTER_PROFILE_DIR}/ssh-publickey" "${HOME}/.ssh/google_compute_engine.pub"

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}/gce.json"
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"
set -x

# Create the network and firewall rules to attach it to VM
gcloud compute networks create "${INSTANCE_PREFIX}" \
  --subnet-mode=custom \
  --bgp-routing-mode=regional
gcloud compute networks subnets create "${INSTANCE_PREFIX}" \
  --network "${INSTANCE_PREFIX}" \
  --range=10.0.0.0/9
gcloud compute firewall-rules create "${INSTANCE_PREFIX}" \
  --network "${INSTANCE_PREFIX}" \
  --allow tcp:22,icmp

# image-family openshift4-libvirt must exist in ${GOOGLE_PROJECT_ID} for this template
# for more info see here: https://github.com/ironcladlou/openshift4-libvirt-gcp/blob/rhel8/IMAGES.md
gcloud compute instances create "${INSTANCE_PREFIX}" \
  --image-family openshift4-libvirt \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --machine-type n1-standard-16 \
  --min-cpu-platform "Intel Haswell" \
  --boot-disk-type pd-ssd \
  --boot-disk-size 256GB \
  --subnet "${INSTANCE_PREFIX}" \
  --network "${INSTANCE_PREFIX}"
