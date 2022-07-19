#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x

echo "entering critest setup!!!!"

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

cat  > "${HOME}"/run-tests.sh << 'EOF'
#!/bin/bash
set -euo pipefail

export HOME=/root
export GOROOT=/usr/local/go
echo GOROOT="/usr/local/go" >> /etc/environment
cat /etc/environment 
mkdir /tmp/artifacts 
mkdir /logs
mkdir /logs/artifacts 
mkdir /tmp/artifacts/logs
dnf install python39 -y
curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python3.9 get-pip.py
python3.9 -m pip install ansible
# setup the directory where the tests will the run
REPO_DIR="/home/crio-test"
mkdir -p "\${REPO_DIR}"
# NVMe makes it faster
NVME_DEVICE="/dev/nvme0n1"
if [ -e "\$NVME_DEVICE" ];
then
mkfs.xfs -f "\${NVME_DEVICE}"
mount "\${NVME_DEVICE}" "\${REPO_DIR}"
fi
# copy the agent sources on the remote machine
tar -xzvf crio-test.tar.gz -C "\${REPO_DIR}"
chown -R root:root "\${REPO_DIR}"
cd "\${REPO_DIR}/contrib/test/ci"
echo "localhost" >> hosts
ansible-playbook integration-main.yml -i hosts -e "TEST_AGENT=prow" -e "GOPATH=/usr/local/go" --connection=local -vvv
EOF

chmod +x "${HOME}"/run-tests.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  packer@"${INSTANCE_PREFIX}" \
  --command '/home/rhel8user/run-tests.sh'
