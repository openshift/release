#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"

mkdir -p "${HOME}"/.ssh
chmod 0700 "${HOME}"/.ssh
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

cat  > "${HOME}"/extract-openshift-tests << 'EOF'
#!/bin/bash
set -euxo pipefail
# Tests execution
echo ### Extracting openshift-tests binary
mkdir "${HOME}"/os-tests
cd "${HOME}"/os-tests
export TESTS_IMAGE=$(oc -a "${HOME}"/pull-secret adm release info --image-for=tests "${RELEASE_IMAGE_LATEST}")
oc -a ~/pull-secret image extract "${TESTS_IMAGE}" --path=/usr/bin/openshift-tests:"${HOME}"/os-tests/.
chmod +x openshift-tests
sudo mv "${HOME}"/os-tests/openshift-tests /usr/local/bin/
EOF
chmod +x "${HOME}"/extract-openshift-tests

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/pull-secret packer@"${INSTANCE_PREFIX}":/home/packer/pull-secret

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/extract-openshift-tests packer@"${INSTANCE_PREFIX}":/home/packer/extract-openshift-tests

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  packer@"${INSTANCE_PREFIX}" \
  --command "export RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST} && /home/packer/extract-openshift-tests"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /bin/openshift-install packer@"${INSTANCE_PREFIX}":/home/packer/openshift-install

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  packer@"${INSTANCE_PREFIX}" \
  --command 'sudo mv /home/packer/openshift-install /usr/local/bin/openshift-install'

set +x
echo "Will now launch libvirt cluster in the gce instance with ${RELEASE_IMAGE_LATEST}"
# Install allows up to 30min beyond than what installer allows by default. In the create-cluster script
# see the `wait-for install-complete` added here: https://github.com/ironcladlou/openshift4-libvirt-gcp/blob/rhel8/tools/create-cluster
# https://github.com/openshift/installer/issues/3043
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  packer@"${INSTANCE_PREFIX}" \
  --command "export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST} OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID} && timeout 150m bash -ce \"create-cluster installer\""
