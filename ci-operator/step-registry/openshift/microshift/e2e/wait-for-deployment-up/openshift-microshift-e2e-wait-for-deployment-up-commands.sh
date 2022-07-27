#!/bin/bash

set -xeuo pipefail

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

cat > "${HOME}"/wait_for_deployment_ready.sh <<'EOF'
#!/bin/bash
set -xeuo pipefail

export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig
echo "waiting for deployment response" >&2
oc wait --for=condition=available --timeout=120s deployment nginx
echo "deployment posted ready status" >&2
EOF
chmod +x "${HOME}"/wait_for_deployment_ready.sh

# restart the VM
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute instances start "${INSTANCE_PREFIX}" --zone "${GOOGLE_COMPUTE_ZONE}"

# Steps may not be used more than once in a test, so this block duplicates the behavior of wait-for-ssh for reboot tests.
timeout=1200 # 20 minute wait.  
>&2 echo "Polling ssh connectivity before proceeding.  Timeout=$timeout second"
start=$(date +"%s")
until LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'echo Hello, CI';
do
  if (( $(date +"%s") - $start >= $timeout )); then
    echo "timed out out waiting for ssh connection" >&2
    exit 1
  fi
  echo "waiting for ssh connection"
done
>&2 echo "It took $timeout seconds to connect via ssh"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/wait_for_deployment_ready.sh rhel8user@"${INSTANCE_PREFIX}":~/wait_for_deployment_ready.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo ~/wait_for_deployment_ready.sh'
