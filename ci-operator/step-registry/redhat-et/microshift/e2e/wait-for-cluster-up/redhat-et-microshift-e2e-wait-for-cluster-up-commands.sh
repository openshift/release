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

cat > "${HOME}"/wait_for_node_ready.sh <<'EOF'
#!/bin/bash
set -xeuo pipefail

systemctl enable --now microshift.service

microshift-containerized
source /etc/microshift-containerized/microshift-containerized.conf

start=$(date '+%s')
to=300

# Wait for node to post ready
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

EOF
chmod +x "${HOME}"/wait_for_node_ready.sh

# TODO: Remove this ASAP
# Temporary step wait for flannel to be ready, then kill service-ca pod before starting kuttl tests
cat > "${HOME}"/wait_for_flannel.sh <<'EOF'
#!/bin/bash
set -xeuo pipefail

start=$(date '+%s')
to=300

# Wait for flannel to post ready
while :; do
  if [ $(( $(date '+%s') - start )) -ge $to ]; then
    echo "timed out waiting for flannel to start ($to seconds)" >&2
    exit 1
  fi
  echo "waiting for flannel ready" >&2
  # get the condation where type == Ready, where condition.statusx == True.
  flannel="$(oc get pods -n kube-system -o jsonpath='{.items[*].status.conditions}' | jq '.[] | select(.type == "Ready") | select(.status == "True")')" || echo ''
  if [ "$flannel" ]; then
    echo "flannel posted ready status" >&2
    break
  fi
  sleep 10
done
# after flannel ready, kill service-ca pod to workaround current issue
oc delete pods --all -n openshift-service-ca

EOF
chmod +x "${HOME}"/wait_for_flannel.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /tmp/validate-microshift rhel8user@"${INSTANCE_PREFIX}":~/validate-microshift

# TODO: REMOVE
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/wait_for_flannel.sh rhel8user@"${INSTANCE_PREFIX}":~/wait_for_flannel.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/wait_for_node_ready.sh rhel8user@"${INSTANCE_PREFIX}":~/wait_for_node_ready.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo systemctl enable --now microshift.service && sudo KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig && sudo ~/wait_for_node_ready.sh && sudo ~/wait_for_flannel.sh'

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'cd ~/validate-microshift && sudo KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig ./kuttl-test.sh'
