#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"

mkdir -p "${HOME}"/.ssh
mock-nss.sh
chmod 0700 "${HOME}"/.ssh

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

cat  > "${HOME}"/run-tests.sh << 'EOF'
#!/bin/bash
set -euo pipefail
export PATH=/home/packer:$PATH
mkdir -p /tmp/artifacts/junit
# Tests execution
set +e
echo "### Running tests"
openshift-tests run "openshift/conformance/parallel" --dry-run | grep -Ff /home/packer/test-list |openshift-tests run -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
rc=$?
echo "${rc}" > /tmp/test-return
set -e
echo "### Done! (${rc})"
exit 0
EOF
chmod +x "${HOME}"/run-tests.sh

cat  > "${HOME}"/rc.sh << 'EOF'
exit_code=$( cat /tmp/test-return )
if [[ $exit_code -ne 0 ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "${HOME}"/rc.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/run-tests.sh packer@"${INSTANCE_PREFIX}":~/run-tests.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/rc.sh packer@"${INSTANCE_PREFIX}":~/rc.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${SHARED_DIR}"/test-list packer@"${INSTANCE_PREFIX}":~/test-list

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  packer@"${INSTANCE_PREFIX}" \
  --command 'export KUBECONFIG=/home/packer/clusters/installer/auth/kubeconfig && /home/packer/run-tests.sh && echo "### Fetching results" && tar -czvf /tmp/artifacts.tar.gz /tmp/artifacts'

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse packer@"${INSTANCE_PREFIX}":/tmp/artifacts.tar.gz "${HOME}"/artifacts.tar.gz

tar -xzvf "${HOME}"/artifacts.tar.gz -C "${ARTIFACT_DIR}"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  packer@"${INSTANCE_PREFIX}" \
  --command '/home/packer/rc.sh'
