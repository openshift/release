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


cat <<'EOF' > "${HOME}"/suite.txt
"[sig-scheduling] LimitRange should create a LimitRange with defaults and ensure pod has those defaults applied. [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-scheduling] SchedulerPredicates [Serial] validates pod overhead is considered along with resource limits of pods that are allowed to run verify pod overhead is accounted for [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-scheduling] SchedulerPredicates [Serial] validates resource limits of pods that are allowed to run  [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-scheduling] SchedulerPredicates [Serial] validates that NodeAffinity is respected if not matching [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-scheduling] SchedulerPredicates [Serial] validates that NodeSelector is respected if matching  [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-scheduling] SchedulerPredicates [Serial] validates that NodeSelector is respected if not matching  [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-scheduling] SchedulerPredicates [Serial] validates that required NodeAffinity setting is respected if matching [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-scheduling] SchedulerPredicates [Serial] validates that taints-tolerations is respected if matching [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-scheduling] SchedulerPredicates [Serial] validates that taints-tolerations is respected if not matching [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-scheduling] SchedulerPredicates [Serial] validates that there is no conflict between pods with same hostPort but different hostIP and protocol [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-scheduling] SchedulerPreemption [Serial] PreemptionExecutionPath runs ReplicaSets to verify preemption running path [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-scheduling] SchedulerPreemption [Serial] PriorityClass endpoints verify PriorityClass endpoints can be operated with different HTTP methods [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-scheduling] SchedulerPriorities [Serial] Pod should avoid nodes that have avoidPod annotation [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-scheduling] SchedulerPriorities [Serial] Pod should be preferably scheduled to nodes pod can tolerate [Suite:openshift/conformance/serial] [Suite:k8s]"
EOF
chmod +r "${HOME}"/suite.txt

# scp and install microshift.service
  LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/suite.txt rhel8user@"${INSTANCE_PREFIX}":~/suite.txt

