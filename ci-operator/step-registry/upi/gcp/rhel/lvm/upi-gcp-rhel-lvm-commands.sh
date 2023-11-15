#!/bin/bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
INSTANCE_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
# $SHARED_DIR/openshift_gcp_compute_zone should be created by upi-gcp-rhel8-pre.ref
GOOGLE_COMPUTE_ZONE="$(cat "${SHARED_DIR}"/openshift_gcp_compute_zone)"

# Retrieve disk name written by upi-gcp-rhel8-add-disk
GCP_DISK_NAME="$(cat "${SHARED_DIR}"/google_compute_disk_id)"

mkdir -p "${HOME}"/.ssh
mock-nss.sh

echo "$(date -u --rfc-3339=seconds) - Configuring GCP CLI client"
# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" "${HOME}/.ssh/google_compute_engine"
chmod 0600 "${HOME}/.ssh/google_compute_engine"
cp "${CLUSTER_PROFILE_DIR}/ssh-publickey" "${HOME}/.ssh/google_compute_engine.pub"

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}/gce.json"
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute ssh "${INSTANCE_PREFIX}" \
  --command=" sudo dnf install -y lvm2 && \
              sudo pvcreate ${GCP_DISK_NAME} && \
              sudo vgcreate ${LVM_VOLUME_GROUP} ${GCP_DISK_NAME}"
