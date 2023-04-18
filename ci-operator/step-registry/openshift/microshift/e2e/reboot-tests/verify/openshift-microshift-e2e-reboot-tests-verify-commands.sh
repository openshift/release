#!/bin/bash

set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID="$(<${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(<${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

IP_ADDRESS="$(gcloud compute instances describe "${INSTANCE_PREFIX}" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"

mkdir -p "${HOME}"/.ssh
cat << EOF > "${HOME}"/.ssh/config
Host ${INSTANCE_PREFIX}
  User rhel8user
  HostName ${IP_ADDRESS}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}"/.ssh/config

timeout=1200 # 20 minute wait.  
start=$(date +"%s")
until ssh "${INSTANCE_PREFIX}" 'true'; do
  if (( $(date +"%s") - start >= timeout )); then
    echo "timed out out waiting for ssh connection" >&2
    exit 1
  fi
done
>&2 echo "It took $(( $(date +'%s') - start)) seconds to connect via ssh"

cat > "${HOME}"/wait_for_pod_ready.sh <<'EOF'
#!/bin/bash
set -euo pipefail

echo "block until microshift is ready (according to systemd)"
echo "give extra time for api server to update status of the pods"
echo "(immediatelly after reboot, it thinks they're all Running, but it's out of date)"
set -x
systemctl start microshift

export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig
echo "waiting 180s to accomodate for slow kubelet actions with topolvm pvc after reboot"
oc wait --for=condition=Ready --timeout=180s pod/test-pod
EOF
chmod +x "${HOME}"/wait_for_pod_ready.sh
scp "${HOME}"/wait_for_pod_ready.sh "${INSTANCE_PREFIX}":~/wait_for_pod_ready.sh

if ! ssh "${INSTANCE_PREFIX}" 'sudo ~/wait_for_pod_ready.sh'; then
  scp /microshift/validate-microshift/cluster-debug-info.sh "${INSTANCE_PREFIX}":~
  ssh "${INSTANCE_PREFIX}" 'export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig; sudo -E ~/cluster-debug-info.sh'
  exit 1
fi
