#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
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

mapfile -t ZONES < <(gcloud compute zones list --filter="region=${GOOGLE_COMPUTE_REGION}" --format='csv[no-heading](name)')
if [[ ${#ZONES[@]} -eq 0 ]]; then
  echo "$(date -u --rfc-3339=seconds) - No zones found in region ${GOOGLE_COMPUTE_REGION}"
  exit 1
fi
echo "${ZONES[0]}" > "${SHARED_DIR}/openshift_gcp_compute_zone"

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

CPU_PLATFORM_ARGS=()
if [[ -n "${CPU_PLATFORM}" ]]; then
  CPU_PLATFORM_ARGS=(--min-cpu-platform "${CPU_PLATFORM}")
fi

GOOGLE_COMPUTE_ZONE=""
for zone in "${ZONES[@]}"; do
  echo "$(date -u --rfc-3339=seconds) - Creating VM ${INSTANCE_PREFIX} in zone ${zone}..."
  echo "${zone}" > "${SHARED_DIR}/openshift_gcp_compute_zone"
  gcloud --quiet config set compute/zone "${zone}"
  if gcloud compute instances create "${INSTANCE_PREFIX}" \
    --image-family "${INSTANCE_IMAGE}" \
    --image-project rhel-cloud \
    --enable-nested-virtualization \
    "${CPU_PLATFORM_ARGS[@]}" \
    --zone "${zone}" \
    --machine-type "${MACHINE_TYPE}" \
    --boot-disk-type pd-ssd \
    --boot-disk-size 256GB \
    --subnet "${INSTANCE_PREFIX}" \
    --network "${INSTANCE_PREFIX}"; then
    GOOGLE_COMPUTE_ZONE="${zone}"
    break
  fi
  echo "$(date -u --rfc-3339=seconds) - Failed to create VM in ${zone}; trying the next zone"
done

if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Failed to create VM ${INSTANCE_PREFIX} in any zone of ${GOOGLE_COMPUTE_REGION}: ${ZONES[*]}"
  exit 1
fi
