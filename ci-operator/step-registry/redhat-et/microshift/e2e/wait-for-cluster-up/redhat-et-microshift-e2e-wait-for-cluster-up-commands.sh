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

# Give microshift a bit to start infra pods
sleep 300

# Wait for pods to post ready condition
start=$(date '+%s')
to=600

# Until timemout, get all pods in cluster and check their phases.  If any are not "Running,"
# wait a bit and try again.
while :; do

  pods_statuses="$(kubectl get pods -A --no-headers -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase')"

  all_ready=0
  while read -er line; do
    ns=$(echo "$line" | awk '{ print $1 }')
    pod=$(echo "$line" | awk '{ print $2}')
    status=$(echo "$line" | awk '{ print $3 }')
    echo "Pod $ns/$pod posted status: $status"
    if [ "$status" != "Running" ]; then
      echo "Pod $ns/$pod posted status: $status, waiting for the cluster to settle"
      all_ready=1
      break
    fi
  done <<< $pods_statuses
  if [ $all_ready -eq 0 ]; then
    echo "All pods posted Running, continuing"
    break
  fi
  if [ $(( $(date '+%s') - start )) -ge $to ]; then
    echo "Infra pods failed to run after $to seconds" >&2
    echo "$pods_statuses" >&2
    exit 1
  fi
  sleep 20
done
EOF
chmod +x "${HOME}"/wait_for_node_ready.sh


LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/wait_for_node_ready.sh rhel8user@"${INSTANCE_PREFIX}":~/wait_for_node_ready.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo ~/wait_for_node_ready.sh'
