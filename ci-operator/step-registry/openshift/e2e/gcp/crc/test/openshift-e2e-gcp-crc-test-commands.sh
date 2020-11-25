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
mkdir -p /tmp/artifacts

function run-tests() {
  export MIRROR="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp-dev-preview/"

  export OPENSHIFT_PULL_SECRET_PATH="${HOME}"/pull-secret
  export OPENSHIFT_VERSION="$(curl -L "${MIRROR}"/latest/release.txt | sed -n 's/^ *Version: *//p')"
  BUNDLE_VERSION=${OPENSHIFT_VERSION}

  # clone the snc repo
  git clone https://github.com/code-ready/snc.git
  pushd snc
  ./ci.sh
  popd

  # Unset the kubeconfig which is set by snc
  unset KUBECONFIG

  # Delete the dnsmasq config created by snc
  # otherwise snc set the domain entry with 192.168.126.11
  # and crc set it in another file 192.168.130.11 so
  # better to remove the dnsmasq config after running snc
  sudo rm -fr /etc/NetworkManager/dnsmasq.d/*
  sudo systemctl reload NetworkManager

  # clone the crc repo
  git clone https://github.com/code-ready/crc.git
  pushd crc
  make BUNDLE_VERSION="${BUNDLE_VERSION}" cross
  export PULL_SECRET_FILE=--pull-secret-file="${HOME}"/pull-secret
  export BUNDLE_LOCATION=--bundle-location="${HOME}"/snc/crc_libvirt_"${BUNDLE_VERSION}".crcbundle
  export CRC_BINARY=--crc-binary="${HOME}"/crc/out/linux-amd64
  make integration GODOG_OPTS="--godog.tags='~@story_registry && @linux'"
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

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  packer@"${INSTANCE_PREFIX}" \
  --command 'sudo rm -fr /usr/local/go; sudo yum install -y podman make golang'

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  packer@"${INSTANCE_PREFIX}" \
  --command "export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}  && timeout 360m bash -ce \"/home/packer/run-tests.sh\""
