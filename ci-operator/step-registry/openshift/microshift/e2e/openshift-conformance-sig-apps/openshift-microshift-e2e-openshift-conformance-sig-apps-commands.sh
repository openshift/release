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
"[sig-apps] CronJob should be able to schedule after more than 100 missed schedule [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] CronJob should delete failed finished jobs with limit of one job [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] CronJob should delete successful finished jobs with limit of one successful job [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] CronJob should not emit unexpected warnings [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] CronJob should remove from active list jobs that have been deleted [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] CronJob should replace jobs when ReplaceConcurrent [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] CronJob should schedule multiple jobs concurrently [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] Daemon set [Serial] should not update pod when spec was updated and update strategy is OnDelete [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-apps] Daemon set [Serial] should retry creating failed daemon pods [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-apps] Daemon set [Serial] should run and stop complex daemon [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-apps] Daemon set [Serial] should run and stop complex daemon with node affinity [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-apps] Daemon set [Serial] should run and stop simple daemon [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-apps] Daemon set [Serial] should update pod when spec was updated and update strategy is RollingUpdate [Conformance] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-apps] Deployment deployment reaping should cascade to its replica sets and pods [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] Deployment deployment should delete old replica sets [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] Deployment deployment should support proportional scaling [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] Deployment deployment should support rollover [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] Deployment iterative rollouts should eventually progress [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] Deployment RecreateDeployment should delete old pods and create new ones [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] Deployment RollingUpdateDeployment should delete old pods and create new ones [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] Deployment should run the lifecycle of a Deployment [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] Deployment test Deployment ReplicaSet orphaning and adoption regarding controllerRef [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] DisruptionController evictions: enough pods, absolute => should allow an eviction [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] DisruptionController evictions: enough pods, replicaSet, percentage => should allow an eviction [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] DisruptionController evictions: maxUnavailable allow single eviction, percentage => should allow an eviction [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] DisruptionController evictions: maxUnavailable deny evictions, integer => should not allow an eviction [Serial] [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-apps] DisruptionController evictions: no PDB => should allow an eviction [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] DisruptionController evictions: too few pods, absolute => should not allow an eviction [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] DisruptionController evictions: too few pods, replicaSet, percentage => should not allow an eviction [Serial] [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-apps] DisruptionController Listing PodDisruptionBudgets for all namespaces should list and delete a collection of PodDisruptionBudgets [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] DisruptionController should block an eviction until the PDB is updated to allow it [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] DisruptionController should create a PodDisruptionBudget [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] DisruptionController should observe PodDisruptionBudget status updated [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] DisruptionController should update/patch PodDisruptionBudget status [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] Job should adopt matching orphans and release non-matching pods [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] Job should delete a job [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] Job should fail to exceed backoffLimit [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] Job should fail when exceeds active deadline [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] Job should remove pods when job is deleted [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] Job should run a job to completion when tasks sometimes fail and are locally restarted [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] Job should run a job to completion when tasks succeed [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] ReplicaSet should adopt matching pods on creation and release no longer matching pods [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] ReplicaSet should serve a basic image on each replica with a public image  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] ReplicaSet should surface a failure condition on a common issue like exceeded quota [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] ReplicationController should adopt matching pods on creation [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] ReplicationController should release no longer matching pods [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] ReplicationController should serve a basic image on each replica with a public image  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] ReplicationController should surface a failure condition on a common issue like exceeded quota [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] ReplicationController should test the lifecycle of a ReplicationController [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should have a working scale subresource [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should implement legacy replacement when the update strategy is OnDelete [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should perform canary updates and phased rolling updates of template modifications [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] should perform rolling updates and roll backs of template modifications [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-apps] StatefulSet [k8s.io] Basic StatefulSet functionality [StatefulSetBasic] Should recreate evicted statefulset [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
EOF
chmod +r "${HOME}"/suite.txt

# scp and install microshift.service
  LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/suite.txt rhel8user@"${INSTANCE_PREFIX}":~/suite.txt

