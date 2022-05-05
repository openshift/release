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

cat > "${HOME}"/start_microshift.sh <<'EOF'
#!/bin/bash
set -xeuo pipefail

trap "sudo journalctl -eu microshift" EXIT

sudo systemctl enable microshift --now

# If condition is true there is podman, it's not a rpm install.
if [[ $(command -v podman) ]]; then
  # podman is present so copy the config file
  sudo mkdir -p /var/lib/microshift/resources/kubeadmin/
  sudo podman cp microshift:/var/lib/microshift/resources/kubeadmin/kubeconfig /var/lib/microshift/resources/kubeadmin/kubeconfig  
else
  echo "This is rpm run";

  # test if microshift is running
  sudo systemctl status microshift;

  # test if microshift created the kubeconfig under /var/lib/microshift/resources/kubeadmin/kubeconfig
  while ! sudo test -f "/var/lib/microshift/resources/kubeadmin/kubeconfig";
  do
    echo "Waiting for kubeconfig..."
    sleep 5;
  done
  sudo ls -la /var/lib/microshift
  sudo ls -la /var/lib/microshift/resources/kubeadmin/kubeconfig
  
fi
EOF

chmod +x "${HOME}"/start_microshift.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /tmp/validate-microshift rhel8user@"${INSTANCE_PREFIX}":~/validate-microshift

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/start_microshift.sh rhel8user@"${INSTANCE_PREFIX}":~/start_microshift.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command '/home/rhel8user/start_microshift.sh'

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'cd ~/validate-microshift  && sudo KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig ./kuttl-test.sh'