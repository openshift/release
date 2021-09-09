#! /bin/bash

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



cat  > "${HOME}"/run-smoke-tests.sh << 'EOF'
#!/bin/bash
set -xeuo pipefail

systemctl disable --now firewalld

export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig

ln -s /usr/bin/oc /usr/bin/kubectl

systemctl enable --now microshift.service
start=$(date '+%s')
to=300
while :; do
  if [ $(( $(date '+%s') - start )) -ge $to ]; then
    echo "timed out waiting for node to start ($to seconds)" >&2
    exit 1
  fi
  echo "waiting for node response" >&2
  # get the condation where type == Ready, where condition.statusx == True.
  node="$(oc get nodes -o jsonpath='{.items[*].status.conditions}' | jq '.[] | select(.type == "Ready") | select(.status == "True")')" || echo ''
  if [ "$node" ]; then
    echo "node posted ready status" >&2
    break
  fi
  sleep 10
done

cat suite.txt | openshift-tests run --provider=none --run -

EOF
chmod +x "${HOME}"/run-smoke-tests.sh

# scp smoke test script and pull secret
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/run-smoke-tests.sh rhel8user@"${INSTANCE_PREFIX}":~/run-smoke-tests.sh

# start the test
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo ./run-smoke-tests.sh'