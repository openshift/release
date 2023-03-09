#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
set -x

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}-${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID=$(< "${CLUSTER_PROFILE_DIR}/openshift_gcp_project")
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE=$(< "${SHARED_DIR}/openshift_gcp_compute_zone")
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

cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/pull-secret

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

gcloud compute firewall-rules update "${INSTANCE_PREFIX}" --allow tcp:22,icmp,tcp:80

cat <<'EOF' > "${HOME}"/greenboot_check.sh
#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
set -x

#
# See https://github.com/openshift/microshift/blob/main/docs/greenboot_dev.md#user-workload-health
#
SCRIPT_FILE=/etc/greenboot/check/required.d/50_busybox_running_check.sh
sudo curl -s https://raw.githubusercontent.com/openshift/microshift/main/docs/config/busybox_running_check.sh -o \${SCRIPT_FILE}
sudo chmod 755 \${SCRIPT_FILE}

sudo systemctl restart microshift

for check_script in $(find /etc/greenboot/check/ -name \*.sh | sort) ; do
  echo Running \${check_script}...
  \${check_script}
done
EOF

chmod +x "${HOME}/greenboot_check.sh"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}/greenboot_check.sh" "rhel8user@${INSTANCE_PREFIX}:~/greenboot_check.sh"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute ssh \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  "rhel8user@${INSTANCE_PREFIX}" \
  --command "bash ~/greenboot_check.sh"
