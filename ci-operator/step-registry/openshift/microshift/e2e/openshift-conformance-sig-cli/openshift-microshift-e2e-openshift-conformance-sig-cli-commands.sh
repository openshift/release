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
"[sig-cli] Kubectl client Kubectl api-versions should check if v1 is in available api versions  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl apply apply set/view last-applied [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl apply should apply a new configuration to an existing RC [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl apply should reuse port when apply to an existing SVC [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl client-side validation should create/apply a CR with unknown fields for CRD with no validation schema [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl client-side validation should create/apply a valid CR for CRD with validation schema [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl client-side validation should create/apply a valid CR with arbitrary-extra properties for CRD with partially-specified validation schema [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl cluster-info dump should check if cluster-info dump succeeds [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl cluster-info should check if Kubernetes control plane services is included in cluster-info  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl copy should copy a file from a running Pod [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl create quota should create a quota without scopes [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl create quota should create a quota with scopes [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl create quota should reject quota with invalid scopes [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl describe should check if kubectl describe prints relevant information for cronjob [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl describe should check if kubectl describe prints relevant information for rc and pods  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl diff should check if kubectl diff finds a difference for Deployments [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl expose should create services for rc  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl get componentstatuses should get componentstatuses [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl label should update the label on a resource  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl logs should be able to retrieve and filter logs  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl patch should add annotations for pods in rc  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl replace should update a single-container pod's image  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl run pod should create a pod from an image when restart is Never  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl server-side dry-run should check if kubectl can dry-run update Pods [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl taint [Serial] should remove all the taints with the same key off a node [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl taint [Serial] should update the taint on a node [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-cli] Kubectl client Kubectl version should check is all data is printed  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Proxy server should support proxy with --port 0  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Proxy server should support --unix-socket=/path  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Simple pod should contain last line of the log [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Simple pod should support exec [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Simple pod should support exec through kubectl proxy [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Simple pod should support exec using resource/name [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Simple pod should support inline execution and attach [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Simple pod should support port-forward [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl client Update Demo should create and stop a replication controller  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl client Update Demo should scale a replication controller  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-cli] Kubectl Port forwarding With a server listening on 0.0.0.0 should support forwarding over websockets [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl Port forwarding With a server listening on 0.0.0.0 that expects a client request should support a client that connects, sends DATA, and disconnects [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl Port forwarding With a server listening on 0.0.0.0 that expects a client request should support a client that connects, sends NO DATA, and disconnects [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl Port forwarding With a server listening on 0.0.0.0 that expects NO client request should support a client that connects, sends DATA, and disconnects [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl Port forwarding With a server listening on localhost should support forwarding over websockets [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl Port forwarding With a server listening on localhost that expects a client request should support a client that connects, sends DATA, and disconnects [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl Port forwarding With a server listening on localhost that expects a client request should support a client that connects, sends NO DATA, and disconnects [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-cli] Kubectl Port forwarding With a server listening on localhost that expects NO client request should support a client that connects, sends DATA, and disconnects [Suite:openshift/conformance/parallel] [Suite:k8s]"
EOF
chmod +r "${HOME}"/suite.txt

# scp and install microshift.service
  LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/suite.txt rhel8user@"${INSTANCE_PREFIX}":~/suite.txt

