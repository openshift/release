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

cat << 'EOFEOF' > "${HOME}/greenboot_check.sh"
#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
set -x

function check_greenboot_exit_status() {
  local expectedRC=$1
  local cleanup=$2

  if [ ${cleanup} -ne 0 ] ; then
    echo 1 | microshift-cleanup-data --all
    systemctl enable --now microshift || true
  fi

  for check_script in $(find /etc/greenboot/check/ -name \*.sh | sort) ; do
    echo Running ${check_script}...
    local currentRC=1
    if ${check_script} ; then
      currentRC=0
    fi

    if [ ${currentRC} != ${expectedRC} ] ; then
      exit 1
    fi
  done
}

#
# Initial check must succeed (set timeout of 180s to speed up the process)
#
tee /etc/greenboot/greenboot.conf &>/dev/null <<EOF
MICROSHIFT_WAIT_TIMEOUT_SEC=180
EOF
check_greenboot_exit_status 0 1

#
# User workload health
# See https://github.com/openshift/microshift/blob/main/docs/greenboot_dev.md#user-workload-health
#
MANIFEST_DIR=/etc/microshift/manifests
mkdir -p ${MANIFEST_DIR}

tee ${MANIFEST_DIR}/busybox.yaml &>/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: busybox
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: busybox-deployment
spec:
  selector:
    matchLabels:
      app: busybox
  template:
    metadata:
      labels:
        app: busybox
    spec:
      containers:
      - name: busybox
        image: BUSYBOX_IMAGE
        command:
          - sleep
          - "3600"
EOF

tee ${MANIFEST_DIR}/kustomization.yaml &>/dev/null <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: busybox
resources:
  - busybox.yaml
images:
  - name: BUSYBOX_IMAGE
    newName: busybox:1.35
EOF

SCRIPT_FILE=/etc/greenboot/check/required.d/50_busybox_running_check.sh
# The file comes from payload.tar
ln -s $(which busybox_running_check.sh) ${SCRIPT_FILE}

check_greenboot_exit_status 0 1
rm -f ${SCRIPT_FILE}
rm -f /etc/microshift/manifests/*

#
# Service failure
# See https://github.com/openshift/microshift/blob/main/docs/greenboot_dev.md#microshift-service-failure
#
dnf remove -y hostname
check_greenboot_exit_status 1 1
dnf install -y hostname

#
# Pod failure
# https://github.com/openshift/microshift/blob/main/docs/greenboot_dev.md#microshift-pod-failure
#
YAML_FILE=/etc/microshift/config.yaml
tee ${YAML_FILE} &>/dev/null <<EOF
network:
  serviceNetwork:
  - 10.66.0.0/16
EOF

check_greenboot_exit_status 1 0
rm -f ${YAML_FILE}

#
# Last check must succeed
#
check_greenboot_exit_status 0 1
EOFEOF

chmod +x "${HOME}/greenboot_check.sh"

gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}/greenboot_check.sh" "rhel8user@${INSTANCE_PREFIX}:~/greenboot_check.sh"

if ! gcloud compute ssh \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  "rhel8user@${INSTANCE_PREFIX}" \
  --command "sudo ~/greenboot_check.sh"; then

  gcloud compute scp \
    --quiet \
    --project "${GOOGLE_PROJECT_ID}" \
    --zone "${GOOGLE_COMPUTE_ZONE}" \
    --recurse /tmp/validate-microshift rhel8user@"${INSTANCE_PREFIX}":~/validate-microshift

  gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
    --zone "${GOOGLE_COMPUTE_ZONE}" \
    rhel8user@"${INSTANCE_PREFIX}" \
    --command 'chmod +x ~/validate-microshift/cluster-debug-info.sh && sudo ~/validate-microshift/cluster-debug-info.sh'

  exit 1
fi
