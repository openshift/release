#!/bin/bash

set -euo pipefail

HYPERFLEET_E2E_CREDENTIALS_PATH="/var/run/hyperfleet-e2e/"
export GOOGLE_APPLICATION_CREDENTIALS="${HYPERFLEET_E2E_CREDENTIALS_PATH}/hcm-hyperfleet-e2e.json"

log() {
    echo "$(date -u --rfc-3339=seconds) ${*}"
}

# Install gcloud if it is not present in the step image.
function gcloud_install() {
  if ! which gcloud; then
    local tarball="google-cloud-cli-linux-x86_64.tar.gz"
    log "gcloud not installed, installing from https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${tarball}"
    pushd "${HOME}"
    curl -sSLO "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${tarball}"
    tar -xzf "${tarball}"
    export PATH="${HOME}/google-cloud-sdk/bin:${PATH}"
    popd
  fi
}

gcloud_install
gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"
PROJECT_ID="$(jq -r -c .project_id "${GOOGLE_APPLICATION_CREDENTIALS}")"
gcloud config set project "${PROJECT_ID}"

# Unique, lowercase instance name derived from the build ID.
VM_NAME="hf-vm-${BUILD_ID}"
VM_NAME="${VM_NAME,,}"
FIREWALL_RULE="${VM_NAME}-allow-ssh"
SSH_USER="prow"

# Generate an SSH keypair for this run. The public key is injected via instance
# metadata; the private key is shared with the test step via ${SHARED_DIR}.
ssh-keygen -t ed25519 -N "" -f "${SHARED_DIR}/vm_ssh_key" -C "${SSH_USER}" >/dev/null
chmod 400 "${SHARED_DIR}/vm_ssh_key"
PUB_KEY="$(cat "${SHARED_DIR}/vm_ssh_key.pub")"

log "Creating GCP VM ${VM_NAME} in ${GCP_VM_ZONE}"
# Labels follow the infra repo convention (terraform/main.tf common_labels) so
# the VM is attributable in cost tracking and can be reaped if the destroy
# step never runs. TTL gives a 24h grace period beyond the job timeout.
VM_TTL="$(date -u -d "+${GCP_VM_TTL_HOURS} hours" +%Y-%m-%d)"
gcloud compute instances create "${VM_NAME}" \
  --image-family="${GCP_VM_IMAGE_FAMILY}" \
  --image-project="${GCP_VM_IMAGE_PROJECT}" \
  --machine-type="${GCP_VM_MACHINE_TYPE}" \
  --boot-disk-size="${GCP_VM_BOOT_DISK_SIZE}" \
  --zone="${GCP_VM_ZONE}" \
  --tags="${VM_NAME}" \
  --labels="managed-by=prow,owner=hyperfleet-ci,project=hyperfleet,ttl=${VM_TTL}" \
  --metadata="ssh-keys=${SSH_USER}:${PUB_KEY}"

# GCP VPC firewall rules are tag-scoped, so this ingress rule applies only to
# this instance. It is removed by the destroy step.
gcloud compute firewall-rules create "${FIREWALL_RULE}" \
  --allow=tcp:22 \
  --source-ranges=0.0.0.0/0 \
  --target-tags="${VM_NAME}"

PUBLIC_IP="$(gcloud compute instances describe "${VM_NAME}" \
  --zone="${GCP_VM_ZONE}" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
if [[ -z "${PUBLIC_IP}" ]]; then
  log "ERROR: failed to get public IP for ${VM_NAME}"
  exit 1
fi

# Share everything the test and destroy steps need.
echo "${VM_NAME}" > "${SHARED_DIR}/gcp_vm_name"
echo "${GCP_VM_ZONE}" > "${SHARED_DIR}/gcp_vm_zone"
echo "${FIREWALL_RULE}" > "${SHARED_DIR}/gcp_vm_firewall_rule"
echo "${PUBLIC_IP}" > "${SHARED_DIR}/gcp_vm_public_ip"
echo "${SSH_USER}" > "${SHARED_DIR}/gcp_vm_ssh_user"

log "VM ${VM_NAME} created with public IP ${PUBLIC_IP}"

# Wait for the VM to accept SSH connections.
SSH_OPTS=(-o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" \
  -i "${SHARED_DIR}/vm_ssh_key" "${SSH_USER}@${PUBLIC_IP}")
_timeout=300
_elapsed=0
_step=15
log "Waiting up to ${_timeout}s for VM to be ready"
while ! ssh "${SSH_OPTS[@]}" true 2>/dev/null; do
  if (( _elapsed >= _timeout )); then
    log "ERROR: timeout (${_timeout}s) waiting for VM to be ready"
    exit 1
  fi
  sleep "${_step}"
  _elapsed=$(( _elapsed + _step ))
done
log "VM ready after ${_elapsed}s"
