#!/bin/bash

set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub
echo 'ServerAliveInterval 30' | tee -a "${HOME}"/.ssh/config
echo 'ServerAliveCountMax 1200' | tee -a "${HOME}"/.ssh/config
chmod 0600 "${HOME}"/.ssh/config

# Copy pull secret to user home
cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/pull-secret

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

# Run openshift/conformance test suite
# Later on a list of skipped tests can be provided and filtered out
# from the suite using combination of "openshift-tests run openshift/conformance --dry-run | grep "client-go should negotiate watch and report errors with accept" | openshift-tests run -v 2 --provider=none -o /home/rhel8user/e2e.log --junit-dir /home/rhel8user/junit -f -"
# #openshift-tests run openshift/conformance -v 2 --provider=none -o /home/rhel8user/e2e.log --junit-dir /home/rhel8user/junit
echo "TEST_SKIPS: ${TEST_SKIPS}"

if [[ -n "${TEST_SKIPS}" ]]; then
    export TESTS="$(openshift-tests run --dry-run --provider=none "${TEST_SUITE}")"
    echo "${TESTS}" | grep -v "${TEST_SKIPS}" >/tmp/tests
    echo "Skipping tests:"
    echo "${TESTS}" | grep "${TEST_SKIPS}" || { exit_code=$?; echo 'Error: no tests were found matching the TEST_SKIPS regex:'; echo "$TEST_SKIPS"; return $exit_code; }
    TEST_ARGS="${TEST_ARGS:-} --file /tmp/tests"
fi

cat  > "${HOME}"/run-test.sh <<EOF
export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig
openshift-tests run ${TEST_SUITE} ${TEST_ARGS:-} -v 2 --provider=none -o /home/rhel8user/e2e.log --junit-dir /home/rhel8user/junit
chown rhel8user:rhel8user /home/rhel8user/e2e.log
chown -R rhel8user:rhel8user /home/rhel8user/junit
EOF
chmod +x "${HOME}"/run-test.sh

# scp the test runner script, execute it and collect artifacts
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/run-test.sh rhel8user@"${INSTANCE_PREFIX}":~/run-test.sh

# scp openshift-test bin
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /usr/bin/openshift-tests rhel8user@"${INSTANCE_PREFIX}":~/openshift-tests

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo mv openshift-tests /usr/bin/openshift-tests'

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo ~/run-test.sh'

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse rhel8user@"${INSTANCE_PREFIX}":~/e2e.log "${ARTIFACT_DIR}/e2e.log"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse rhel8user@"${INSTANCE_PREFIX}":~/junit "${ARTIFACT_DIR}/junit"
