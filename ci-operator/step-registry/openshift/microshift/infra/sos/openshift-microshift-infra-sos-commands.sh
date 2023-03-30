#!/bin/bash

set -eux

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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

gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command "sudo sos report --batch --all-logs --tmp-dir /tmp -p container,network -o logs && sudo chmod +r /tmp/sosreport*"

gcloud compute scp \
--quiet \
--project "${GOOGLE_PROJECT_ID}" \
--zone "${GOOGLE_COMPUTE_ZONE}" \
rhel8user@"${INSTANCE_PREFIX}":/tmp/sosreport* ${ARTIFACT_DIR}/
