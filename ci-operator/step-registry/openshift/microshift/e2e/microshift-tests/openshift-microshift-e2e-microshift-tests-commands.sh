#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
set -x

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}-${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID=$(<"${CLUSTER_PROFILE_DIR}/openshift_gcp_project")
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE=$(<"${SHARED_DIR}/openshift_gcp_compute_zone")
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

mkdir -p "${HOME}"/.ssh
cp "${CLUSTER_PROFILE_DIR}/ssh-privatekey" "${HOME}/.ssh/google_compute_engine"
chmod 0600 "${HOME}/.ssh/google_compute_engine"
cp "${CLUSTER_PROFILE_DIR}/ssh-publickey" "${HOME}/.ssh/google_compute_engine.pub"

cat <<EOF >"${HOME}/.ssh/config"
Host *
    IdentityFile ~/.ssh/google_compute_engine
    ServerAliveInterval 30
    ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}/gce.json"
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

gcloud compute ssh \
  --project "${GOOGLE_PROJECT_ID}" --zone "${GOOGLE_COMPUTE_ZONE}" \
  "rhel8user@${INSTANCE_PREFIX}" --command "ls ~/.ssh/"

gcloud compute ssh \
  --project "${GOOGLE_PROJECT_ID}" --zone "${GOOGLE_COMPUTE_ZONE}" \
  "rhel8user@${INSTANCE_PREFIX}" --command "cat ~/.ssh/*.pub" >>~/.ssh/known_hosts

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

IP_ADDRESS="$(gcloud compute instances describe "${INSTANCE_PREFIX}" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
# gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
#   --zone "${GOOGLE_COMPUTE_ZONE}" \
#   rhel8user@"${INSTANCE_PREFIX}" \
#   --command "sudo cat /var/lib/microshift/resources/kubeadmin/${IP_ADDRESS}/kubeconfig" >/tmp/kubeconfig

ssh "rhel8user@${IP_ADDRESS}" "sudo cat /var/lib/microshift/resources/kubeadmin/${IP_ADDRESS}/kubeconfig" >/tmp/kubeconfig

cd /tmp
git clone https://github.com/pmtk/microshift.git --branch merge-e2e-tests

KUBECONFIG=/tmp/kubeconfig \
  USHIFT_IP="${IP_ADDRESS}" \
  USHIFT_USER=rhel8user \
  ./microshift/e2e/main.sh
