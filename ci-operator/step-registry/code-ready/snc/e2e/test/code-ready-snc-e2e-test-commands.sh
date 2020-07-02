#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"

mkdir -p "${HOME}"/.ssh
mock-nss.sh

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub

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

function run-tests() {
  pushd snc
  set -e
  export OPENSHIFT_PULL_SECRET_PATH="${HOME}"/pull-secret
  ./snc.sh
  if [[ $? -ne 0 ]]; then
    exit 1
  fi
  # wait till the cluster is stable
  sleep 5m
  export KUBECONFIG=crc-tmp-install-data/auth/kubeconfig

  # Wait till all the pods are either running or completed or in terminating state
  while oc get pod --no-headers --all-namespaces | grep -v Running | grep -v Completed | grep -v Terminating; do
     sleep 2
  done

  # Check the cluster operator output, status for available should be true for all operators
  while oc get co -ojsonpath='{.items[*].status.conditions[?(@.type=="Available")].status}' | grep -v True; do
     sleep 2
  done

  # Run createdisk script
  export OPENSHIFT_VERSION=4.x.ci
  export SNC_VALIDATE_CERT=false
  ./createdisk.sh crc-tmp-install-data
  popd
}

run-tests
EOF

chmod +x "${HOME}"/run-tests.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/run-tests.sh packer@"${INSTANCE_PREFIX}":~/run-tests.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/pull-secret packer@"${INSTANCE_PREFIX}":~/pull-secret

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /opt/snc packer@"${INSTANCE_PREFIX}":~/snc

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  packer@"${INSTANCE_PREFIX}" \
  --command "export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}  && timeout 360m bash -ce \"/home/packer/run-tests.sh\""
