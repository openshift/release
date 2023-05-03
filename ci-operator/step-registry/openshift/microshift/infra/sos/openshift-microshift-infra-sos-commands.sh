#!/bin/bash

set -eux

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

echo "CLUSTER_TYPE is ${CLUSTER_TYPE}"
case "${CLUSTER_TYPE}" in
gcp)
  INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
  GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
  GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
  GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
  if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
    echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
    exit 1
  fi
  gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
  gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
  gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
  gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"
  IP_ADDRESS="$(gcloud compute instances describe ${INSTANCE_PREFIX} --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
  HOST_USER="rhel8user"
  ;;
aws)
  IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
  HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"
  INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"
  ;;
*)
  echo >&2 "Unsupported CLUSTER_TYPE '${CLUSTER_TYPE}'"
  exit 1
  ;;
esac

mkdir -p "${HOME}"/.ssh
cat << EOF > "${HOME}"/.ssh/config
Host ${INSTANCE_PREFIX}
  User ${HOST_USER}
  HostName ${IP_ADDRESS}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}"/.ssh/config

ssh "${INSTANCE_PREFIX}" \
  "sudo sos report --batch --all-logs --tmp-dir /tmp -p container,network -o logs && sudo chmod +r /tmp/sosreport*"

scp "${INSTANCE_PREFIX}":/tmp/sosreport* ${ARTIFACT_DIR}/
