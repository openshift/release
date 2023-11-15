#!/bin/bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
INSTANCE_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
# $SHARED_DIR/openshift_gcp_compute_zone should be created by upi-gcp-rhel8-pre.ref
GOOGLE_COMPUTE_ZONE="$(cat "${SHARED_DIR}"/openshift_gcp_compute_zone)"

# Create disk defaults
GCP_DISK_NAME="${INSTANCE_PREFIX}-1"
GCP_DISK_SIZE="${GCP_DISK_SIZE:-"10GB"}"

# Persist disk name for follow-on steps

echo -n "/dev/disk/by-id/google-${GCP_DISK_NAME}" > "${SHARED_DIR}/google_compute_disk_id"
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

echo "$(date -u --rfc-3339=seconds) - Creating GCP Persistent Disk ${GCP_DISK_NAME}"
gcloud compute disks create "${GCP_DISK_NAME}" --size="${GCP_DISK_SIZE}"

# The attached disk will be soft-linked on the host as /dev/disk/by-id/google-${GCP_DISK_NAME}
# The softlink suffix is provided via --device-name
echo "$(date -u --rfc-3339=seconds) - Attaching GCP Persistent Disk ${GCP_DISK_NAME} to instance ${INSTANCE_PREFIX}"
gcloud compute instances attach-disk "${INSTANCE_PREFIX}" \
  --disk=${GCP_DISK_NAME} \
  --device-name="${GCP_DISK_NAME}"
gcloud compute instances set-disk-auto-delete "${INSTANCE_PREFIX}" --disk "${GCP_DISK_NAME}"
