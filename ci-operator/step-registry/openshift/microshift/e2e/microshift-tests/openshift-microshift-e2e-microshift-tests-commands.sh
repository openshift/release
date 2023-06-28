#!/usr/bin/env bash

set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
GOOGLE_PROJECT_ID=$(<"${CLUSTER_PROFILE_DIR}/openshift_gcp_project")
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE=$(<"${SHARED_DIR}/openshift_gcp_compute_zone")
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}/gce.json"
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

IP_ADDRESS="$(gcloud compute instances describe "${INSTANCE_PREFIX}" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  User rhel8user
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

firewall::open_port() {
  local port="${1}"
  local protocol="${2:-tcp}"
  gcloud compute firewall-rules create "microshift-${INSTANCE_PREFIX}-${protocol}-${port}" --network "${INSTANCE_PREFIX}" --allow "${protocol}:${port}"
}

firewall::close_port() {
  local port="$1"
  local protocol="${2:-tcp}"
  gcloud compute firewall-rules delete "microshift-${INSTANCE_PREFIX}-${protocol}-${port}"
}

export -f firewall::open_port
export -f firewall::close_port
export INSTANCE_PREFIX

USHIFT_IP="${IP_ADDRESS}" USHIFT_USER=rhel8user /microshift/e2e/main.sh run
