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

cat > "${HOME}"/ignoretests.txt << 'EOF'
[sig-apps] Daemon set [Serial] should rollback without unnecessary restarts [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]
[sig-cli] Kubectl client Kubectl cluster-info should check if Kubernetes control plane services is included in cluster-info  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]
[sig-scheduling] SchedulerPreemption [Serial] validates basic preemption works [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]
[sig-scheduling] SchedulerPreemption [Serial] validates lower priority pod preemption by critical pod [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]
[k8s.io] [sig-node] NoExecuteTaintManager Multiple Pods [Serial] evicts pods with minTolerationSeconds [Disruptive] [Conformance] [Suite:k8s]
[k8s.io] [sig-node] NoExecuteTaintManager Single Pod [Serial] removing taint cancels eviction [Disruptive] [Conformance] [Suite:k8s]
EOF

cat  > "${HOME}"/run-tests.sh << 'EOF'
#!/bin/bash
set -euo pipefail
export PATH=/home/packer:$PATH
mkdir -p /tmp/artifacts

function run-tests() {
  echo "### Extracting openshift-tests binary"
  mkdir $HOME/os-test
  export TESTS_IMAGE=$(oc -a "${HOME}"/pull-secret adm release info --image-for=tests "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}")
  oc -a ~/pull-secret image extract "${TESTS_IMAGE}" --path=/usr/bin/openshift-tests:"${HOME}"/os-test/.
  chmod +x "${HOME}"/os-test/openshift-tests
  sudo mv "${HOME}"/os-test/openshift-tests /usr/local/bin/

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
  popd

  "${HOME}"/crc/out/linux-amd64/crc setup
  "${HOME}"/crc/out/linux-amd64/crc start -p "${HOME}"/pull-secret -m 12000 -b "${HOME}"/snc/crc_libvirt_"${BUNDLE_VERSION}".crcbundle

  export KUBECONFIG="${HOME}"/.crc/machines/crc/kubeconfig
  openshift-tests run kubernetes/conformance --dry-run  | grep -F -v -f "${HOME}"/ignoretests.txt  | openshift-tests run -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit -f -
  rc=$?
  echo "${rc}" > /tmp/test-return
  set -e
  echo "### Done! (${rc})"
  exit 0
}

run-tests
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
  --recurse "${HOME}"/ignoretests.txt packer@"${INSTANCE_PREFIX}":~/ignoretests.txt

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
  --command "export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}  && timeout 360m bash -ce \"/home/packer/run-tests.sh\" && echo \"### Fetching results\" && tar -czvf /tmp/artifacts.tar.gz /tmp/artifacts"

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