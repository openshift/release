#!/bin/bash

set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${UNIQUE_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

IP_ADDRESS="$(gcloud compute instances describe ${INSTANCE_PREFIX} --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"

mkdir -p "${HOME}"/.ssh
cat << EOF > "${HOME}"/.ssh/config
Host ${INSTANCE_PREFIX}
  User rhel8user
  HostName ${IP_ADDRESS}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
EOF
chmod 0600 "${HOME}"/.ssh/config

cat > "${HOME}"/start_microshift.sh <<'EOF'
#!/bin/bash
set -xeuo pipefail

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

scp -r /microshift/validate-microshift "${INSTANCE_PREFIX}":~/validate-microshift
scp "${HOME}"/start_microshift.sh "${INSTANCE_PREFIX}":~/start_microshift.sh
ssh "${INSTANCE_PREFIX}" '/home/rhel8user/start_microshift.sh'
ssh "${INSTANCE_PREFIX}" \
  'cd ~/validate-microshift  && sudo KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig ./kuttl-test.sh'
