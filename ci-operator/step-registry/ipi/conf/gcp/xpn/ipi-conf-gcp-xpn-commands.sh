#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"

fi

XPN_SERVICE_ACCOUNT=`gcloud config get-value account`
HOST_PROJECT="openshift-dev-installer"
# set the project in order to create the resources
gcloud config set project "${HOST_PROJECT}"

echo "$(date -u --rfc-3339=seconds) - Configuring GCP Subnets for Host Project..."

REGION="${LEASED_RESOURCE}"
INSTANCE_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
HOST_PROJECT_CONTROL_SUBNET="${INSTANCE_PREFIX}-subnet-1"
HOST_PROJECT_COMPUTE_SUBNET="${INSTANCE_PREFIX}-subnet-2"
HOST_PROJECT_NETWORK="${INSTANCE_PREFIX}-vpc"
CONTROL_SUBNET_CIDR="10.0.64.0/19"
COMPUTE_SUBNET_CIDR="10.0.128.0/19"
NAT_NAME="${INSTANCE_PREFIX}-nat"

# Create the new VPC for this CI job
gcloud compute networks create "${HOST_PROJECT_NETWORK}" \
       --bgp-routing-mode=regional \
       --subnet-mode=custom

# Create the subnets for the VPC dynamically for this CI job
gcloud compute networks subnets create "${HOST_PROJECT_CONTROL_SUBNET}" \
       --network "${HOST_PROJECT_NETWORK}" \
       --range="${CONTROL_SUBNET_CIDR}" \
       --description "Control subnet creation for CI job GCP xpn" \
       --region "${REGION}"

gcloud compute networks subnets create "${HOST_PROJECT_COMPUTE_SUBNET}" \
       --network "${HOST_PROJECT_NETWORK}" \
       --range="${COMPUTE_SUBNET_CIDR}" \
       --description "Compute subnet creation for CI job GCP xpn" \
       --region "${REGION}"

# Create a router to ensure that traffic can reach the destinations
gcloud compute routers create "${INSTANCE_PREFIX}" \
       --network "${HOST_PROJECT_NETWORK}" \
       --description "Router for the CI job for GCP xpn" \
       --region "${REGION}"

gcloud compute routers nats create "${NAT_NAME}" \
       --router="${INSTANCE_PREFIX}" \
       --region="${REGION}" \
       --auto-allocate-nat-external-ips \
       --nat-all-subnet-ip-ranges

# Allow traffic to pass with firewall rules.
#
# The installer declares the cluster firewall rules on GCPCluster, but CAPG skips
# all firewall reconciliation when a host project is set (shared VPC), so for an
# XPN install nothing creates them. This job therefore brings its own, the same
# way the gcp-provision-firewalls step does for the non-XPN byo-fw jobs, and
# ipi-conf-gcp-firewall-rules-management sets firewallRulesManagement to
# Unmanaged so the installer and cloud-provider-gcp both stay out of the way.
#
# The rules cannot use the installer's own names, which embed the infraID
# ("<clusterName>-<5 random chars>", generated inside the installer and unknown
# here), so they are named after the job and target the network tags pinned on
# the machine pools by ipi-conf-gcp-firewall-rules-management.
CONTROL_PLANE_TAGS="${NETWORK_TAGS_FOR_CONTROL_PLANE_NODES}"
COMPUTE_TAGS="${NETWORK_TAGS_FOR_COMPUTE_NODES}"
ALL_NODE_TAGS="${CONTROL_PLANE_TAGS},${COMPUTE_TAGS}"

# Retained from before the rules below were added: external SSH and ICMP to
# every instance, which the gather steps rely on to reach compute nodes.
gcloud compute firewall-rules create "${INSTANCE_PREFIX}" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow tcp:22,icmp

gcloud compute firewall-rules create "${INSTANCE_PREFIX}-bootstrap-in-ssh" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow tcp:22 \
       --source-ranges "0.0.0.0/0" \
       --target-tags "${CONTROL_PLANE_TAGS}"

gcloud compute firewall-rules create "${INSTANCE_PREFIX}-api" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow tcp:6443 \
       --source-ranges "0.0.0.0/0" \
       --target-tags "${CONTROL_PLANE_TAGS}"

gcloud compute firewall-rules create "${INSTANCE_PREFIX}-health-checks" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow tcp:6080,tcp:6443,tcp:22624 \
       --source-ranges "35.191.0.0/16,130.211.0.0/22,209.85.152.0/22,209.85.204.0/22" \
       --target-tags "${CONTROL_PLANE_TAGS}"

gcloud compute firewall-rules create "${INSTANCE_PREFIX}-etcd" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow tcp:2379-2380 \
       --source-tags "${CONTROL_PLANE_TAGS}" \
       --target-tags "${CONTROL_PLANE_TAGS}"

gcloud compute firewall-rules create "${INSTANCE_PREFIX}-control-plane" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow tcp:10257,tcp:10259,tcp:22623 \
       --source-tags "${ALL_NODE_TAGS}" \
       --target-tags "${CONTROL_PLANE_TAGS}"

gcloud compute firewall-rules create "${INSTANCE_PREFIX}-internal-network" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow icmp,tcp:22 \
       --source-ranges "${CONTROL_SUBNET_CIDR},${COMPUTE_SUBNET_CIDR}" \
       --target-tags "${ALL_NODE_TAGS}"

gcloud compute firewall-rules create "${INSTANCE_PREFIX}-internal-cluster" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow udp:4789,udp:6081,udp:500,udp:4500,esp,tcp:9000-9999,udp:9000-9999,tcp:10250,tcp:30000-32767,udp:30000-32767 \
       --source-tags "${ALL_NODE_TAGS}" \
       --target-tags "${ALL_NODE_TAGS}"

# Konnectivity, which the installer opens for the duration of bootstrap.
gcloud compute firewall-rules create "${INSTANCE_PREFIX}-konnectivity" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow tcp:8091 \
       --source-tags "${ALL_NODE_TAGS}" \
       --target-tags "${CONTROL_PLANE_TAGS}"

# cloud-provider-gcp would normally open these for service-type LoadBalancers,
# but firewallRulesManagement is Unmanaged for this job, so it does not.
gcloud compute firewall-rules create "${INSTANCE_PREFIX}-ingress-k8s-fw" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow tcp:80,tcp:443 \
       --source-ranges "0.0.0.0/0" \
       --target-tags "${ALL_NODE_TAGS}"

gcloud compute firewall-rules create "${INSTANCE_PREFIX}-ingress-k8s-http-hc" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow tcp:30000-32767 \
       --source-ranges "35.191.0.0/16,130.211.0.0/22,209.85.152.0/22,209.85.204.0/22" \
       --target-tags "${ALL_NODE_TAGS}"

# associate the service account with the subnets
# Bind the networkUser role to the service account
cat << EOF > /tmp/subnet-policy.json
{
  "bindings": [
  {
     "members": [
           "serviceAccount:${XPN_SERVICE_ACCOUNT}"
        ],
        "role": "roles/compute.networkUser"
  }
  ],
  "etag": "ACAB"
}
EOF

# apply the subnet policy to the subnets allowing the service account to
# use the subnets.
gcloud beta compute networks subnets set-iam-policy "${HOST_PROJECT_COMPUTE_SUBNET}" \
       /tmp/subnet-policy.json \
       --project "${HOST_PROJECT}" \
       --region "${REGION}"

gcloud beta compute networks subnets set-iam-policy "${HOST_PROJECT_CONTROL_SUBNET}" \
       /tmp/subnet-policy.json \
       --project "${HOST_PROJECT}" \
       --region "${REGION}"

# remove the policy created above
rm -rf subnet-policy.json

# reset the default project to the intended install project
gcloud config set project "${GOOGLE_PROJECT_ID}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-xpn.yaml.patch

cat > "${PATCH}" << EOF
credentialsMode: Passthrough
platform:
  gcp:
    computeSubnet: ${HOST_PROJECT_COMPUTE_SUBNET}
    controlPlaneSubnet: ${HOST_PROJECT_CONTROL_SUBNET}
    network: ${HOST_PROJECT_NETWORK}
    networkProjectID: ${HOST_PROJECT}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
