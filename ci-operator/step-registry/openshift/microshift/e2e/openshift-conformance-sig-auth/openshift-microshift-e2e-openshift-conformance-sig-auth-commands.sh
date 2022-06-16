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
"[sig-auth] Certificates API [Privileged:ClusterAdmin] should support building a client with a CSR [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] Certificates API [Privileged:ClusterAdmin] should support CSR API operations [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-auth] [Feature:NodeAuthenticator] The kubelet can delegate ServiceAccount tokens to the API server [Skipped:ibmcloud] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] [Feature:NodeAuthenticator] The kubelet's main port 10250 should reject requests with no credentials [Skipped:ibmcloud] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] [Feature:NodeAuthorizer] A node shouldn't be able to create another node [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] [Feature:NodeAuthorizer] A node shouldn't be able to delete another node [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] [Feature:NodeAuthorizer] Getting an existing configmap should exit with the Forbidden error [Skipped:ibmcloud] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] [Feature:NodeAuthorizer] Getting an existing secret should exit with the Forbidden error [Skipped:ibmcloud] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] [Feature:NodeAuthorizer] Getting a non-existent configmap should exit with the Forbidden error, not a NotFound error [Skipped:ibmcloud] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] [Feature:NodeAuthorizer] Getting a non-existent secret should exit with the Forbidden error, not a NotFound error [Skipped:ibmcloud] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] [Feature:NodeAuthorizer] Getting a secret for a workload the node has access to should succeed [Skipped:ibmcloud] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] ServiceAccounts should allow opting out of API token automount  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-auth] ServiceAccounts should guarantee kube-root-ca.crt exist in any namespace [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-auth] ServiceAccounts should mount projected service account token [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-auth] ServiceAccounts should run through the lifecycle of a ServiceAccount [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-auth] ServiceAccounts should set ownership and permission when RunAsUser or FsGroup is present [LinuxOnly] [NodeFeature:FSGroup] [Suite:openshift/conformance/parallel] [Suite:k8s]"
EOF
chmod +r "${HOME}"/suite.txt

# scp and install microshift.service
  LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/suite.txt rhel8user@"${INSTANCE_PREFIX}":~/suite.txt

