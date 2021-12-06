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


# Wait for pods to post ready condition
infra_pods=( kube-flannel kubevirt-hostpath-provisioner dns-default node-resolver router-default service-ca )

to=120 # wait 2min per pod.
for pod in ${infra_pods[@]}; do
    start=$(date '+%s')
    echo "Checking pod $pod"
    while :; do
        if [ $(( $(date '+%s') - start )) -ge $to ]; then
            echo "timed out waiting for pod to post Ready: True.  ($to seconds)" >&2
            exit 1
        fi
        namespace_name=( $(oc get pods -A -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name" --no-headers | grep "$pod") )
        if [ -z "$namespace_name[2]" ]; then
            echo "Pod $pod not found"
            # Continue looping until the pod appears or timeout is reached
            wait 10
            continue
        fi
        is_ready="$(oc get pods -n ${namespace_name[@]} -o jsonpath='{.items[*].status.conditions}' | jq '.[] | select(.type == "Ready") | .status == "True"')"
        if [ "$is_ready" = "true" ]; then
            echo "$pod posted condition Ready: True"
            break
        fi
    done
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
