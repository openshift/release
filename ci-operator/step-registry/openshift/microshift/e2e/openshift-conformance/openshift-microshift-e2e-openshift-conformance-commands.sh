#!/bin/bash

set -euo pipefail
set -x

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

BASE_DOMAIN="$(cat ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

mkdir -p "${HOME}"/.ssh

mock-nss.sh

cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub
echo 'ServerAliveInterval 30' | tee -a "${HOME}"/.ssh/config
echo 'ServerAliveCountMax 1200' | tee -a "${HOME}"/.ssh/config
chmod 0600 "${HOME}"/.ssh/config

cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/pull-secret

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command "sudo cat /var/lib/microshift/resources/kubeadmin/${INSTANCE_PREFIX}.${BASE_DOMAIN}/kubeconfig" > /tmp/kubeconfig

if [[ -n "${TEST_SKIPS}" ]]; then
  TESTS="$(KUBECONFIG=/tmp/kubeconfig ${PAYLOAD_PATH}/usr/bin/openshift-tests run --dry-run --provider none "${TEST_SUITE}")" &&
  echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests &&
  echo "Skipping tests:" &&
  echo "${TESTS}" | grep "${TEST_SKIPS}" || { exit_code=$?; echo 'Error: no tests were found matching the TEST_SKIPS regex:'; echo "$TEST_SKIPS"; return $exit_code; } &&
  TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
fi

PATH=${PAYLOAD_PATH}/usr/bin:$PATH KUBECONFIG=/tmp/kubeconfig ${PAYLOAD_PATH}/usr/bin/openshift-tests \
  run "${TEST_SUITE}" ${TEST_ARGS:-} \
  --provider none \
  -o ${ARTIFACT_DIR}/e2e.log \
  --junit-dir ${ARTIFACT_DIR}/junit
