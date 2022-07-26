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
"[sig-network] DNS should provide DNS for ExternalName services [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] DNS should provide DNS for pods for Hostname [LinuxOnly] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] DNS should provide DNS for pods for Subdomain [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] DNS should provide DNS for services  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] DNS should provide DNS for the cluster  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] DNS should provide /etc/hosts entries for the cluster [LinuxOnly] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] DNS should resolve DNS of partial qualified names for services [LinuxOnly] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] DNS should resolve DNS of partial qualified names for the cluster [LinuxOnly] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] DNS should support configurable pod DNS nameservers [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] DNS should support configurable pod resolv.conf [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] EndpointSliceMirroring should mirror a custom Endpoints resource through create update and delete [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] EndpointSlice should create and delete Endpoints and EndpointSlices for a Service with a selector specified [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] EndpointSlice should create Endpoints and EndpointSlices for Pods matching a Service [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] EndpointSlice should have Endpoints and EndpointSlices pointing to API Server [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Ingress API should support creating Ingress API operations [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] IngressClass API  should support creating IngressClass API operations [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] IngressClass [Feature:Ingress] should not set default value if no default IngressClass [Serial] [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-network] IngressClass [Feature:Ingress] should prevent Ingress creation if more than 1 IngressClass marked as default [Serial] [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-network] IngressClass [Feature:Ingress] should set default value on new IngressClass [Serial] [Suite:openshift/conformance/serial] [Suite:k8s]"
"[sig-network] Networking Granular Checks: Pods should function for intra-pod communication: http [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Networking Granular Checks: Pods should function for intra-pod communication: udp [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Networking Granular Checks: Pods should function for node-pod communication: http [LinuxOnly] [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Networking Granular Checks: Pods should function for node-pod communication: udp [LinuxOnly] [NodeConformance] [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Networking should provide Internet connection for containers [Feature:Networking-IPv4] [Skipped:azure] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy API should support creating NetworkPolicy API operations [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should enforce multiple, stacked policies with overlapping podSelectors [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] NetworkPolicy [LinuxOnly] NetworkPolicy between server and client should support allow-all policy [Feature:NetworkPolicy] [Skipped:Network/OpenShiftSDN/Multitenant] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Proxy version v1 should proxy logs on node using proxy subresource  [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Proxy version v1 should proxy logs on node with explicit kubelet port using proxy subresource  [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Proxy version v1 should proxy through a service and a pod  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] SCTP [Feature:SCTP] [LinuxOnly] should allow creating a basic SCTP service with pod and endpoints [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Service endpoints latency should not be very high  [Conformance] [Serial] [Suite:openshift/conformance/serial/minimal] [Suite:k8s]"
"[sig-network] Services should allow pods to hairpin back to themselves through services [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Services should be able to change the type from ClusterIP to ExternalName [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should be able to change the type from ExternalName to ClusterIP [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should be able to change the type from ExternalName to NodePort [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should be able to change the type from NodePort to ExternalName [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should be able to create a functioning NodePort service [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should be able to update service type to NodePort listening on same port number but different protocols [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Services should be rejected when no endpoints exist [Skipped:ibmcloud] [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Services should check NodePort out-of-range [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Services should create endpoints for unready pods [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Services should find a service from listing all namespaces [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should prevent NodePort collisions [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Services should provide secure master service  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should release NodePorts on delete [Suite:openshift/conformance/parallel] [Suite:k8s]"
"[sig-network] Services should serve a basic endpoint from pods  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should serve multiport endpoints from pods  [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network] Services should test the lifecycle of an Endpoint [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
EOF
chmod +r "${HOME}"/suite.txt

# scp and install microshift.service
  LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/suite.txt rhel8user@"${INSTANCE_PREFIX}":~/suite.txt

