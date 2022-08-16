#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
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
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

GOOGLE_COMPUTE_ZONE="$(gcloud compute zones list --filter="region=$GOOGLE_COMPUTE_REGION" --format='csv[no-heading](name)' | head -n 1)"
echo "$GOOGLE_COMPUTE_ZONE" > "$SHARED_DIR/openshift_gcp_compute_zone"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"

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

gcloud compute instances create "${INSTANCE_PREFIX}" \
  --image=rhel-8-v20220719 \
  --image-project=rhel-cloud \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --machine-type e2-standard-8 \
  --boot-disk-type pd-ssd \
  --subnet "${INSTANCE_PREFIX}" \
  --network "${INSTANCE_PREFIX}" \
  --hostname "release-ci-${INSTANCE_PREFIX}.openshift-ci.com"
