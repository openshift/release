#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

GOOGLE_PROJECT_ID="$(<${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
INSTANCE_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"

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

[ -z "$GOOGLE_COMPUTE_ZONE" ] && GOOGLE_COMPUTE_ZONE="$(gcloud compute zones list --filter="region=$GOOGLE_COMPUTE_REGION" --format='csv[no-heading](name)' | head -n 1)"
echo "$GOOGLE_COMPUTE_ZONE" >"${SHARED_DIR}/openshift_gcp_compute_zone"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"

set -x

# Create the network and firewall rules to attach it to VM
gcloud compute networks create "${INSTANCE_PREFIX}" \
    --subnet-mode=custom \
    --bgp-routing-mode=regional \
    --mtu=1500
gcloud compute networks subnets create "${INSTANCE_PREFIX}" \
    --network "${INSTANCE_PREFIX}" \
    --range=10.0.0.0/9
gcloud compute firewall-rules create "${INSTANCE_PREFIX}" \
    --network "${INSTANCE_PREFIX}" \
    --allow tcp:22,icmp

# Steps should specify either an exact image by name, or an image family. Prioritize
#  the exact image, then the image family, and fail otherwise. Defaults should be defined
#  in the accompanying step ref.  IMAGE_OPTION expands to the full CLI flag and arg.
if [ -n "$GOOGLE_COMPUTE_IMAGE_NAME" ]; then
    IMAGE_OPTION="--image=$GOOGLE_COMPUTE_IMAGE_NAME"
elif [ -n "$GOOGLE_COMPUTE_IMAGE_FAMILY" ]; then
    IMAGE_OPTION="--image-family=$GOOGLE_COMPUTE_IMAGE_FAMILY"
else
        echo >&2 'GOOGLE_COMPUTE_IMAGE_NAME or GOOGLE_COMPUTE_IMAGE_FAMILY variables must be specified.'
    exit 1
fi

gcloud compute instances create "$INSTANCE_PREFIX" \
    "$IMAGE_OPTION" \
    --image-project="$GOOGLE_COMPUTE_IMAGE_PROJECT" \
    --zone "$GOOGLE_COMPUTE_ZONE" \
    --machine-type "$GOOGLE_COMPUTE_MACHINE_TYPE" \
    --boot-disk-type pd-ssd \
    --subnet "$INSTANCE_PREFIX" \
    --network "$INSTANCE_PREFIX" \
    --hostname "release-ci-${INSTANCE_PREFIX}.openshift-ci.com"

IP_ADDRESS="$(gcloud compute instances describe ${INSTANCE_PREFIX} --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
HOST_USER="rhel8user"

echo "${HOST_USER}" > "${SHARED_DIR}/ssh_user"
echo "${IP_ADDRESS}" > "${SHARED_DIR}/public_address"
