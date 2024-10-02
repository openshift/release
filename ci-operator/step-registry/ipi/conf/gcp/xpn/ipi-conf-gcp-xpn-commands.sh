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

# Allow traffic to pass with firewall rules
gcloud compute firewall-rules create "${INSTANCE_PREFIX}" \
       --network "${HOST_PROJECT_NETWORK}" \
       --allow tcp:22,icmp

# TODO: Check that the service account has all of the correct permissions here. There
# is still a failure occurring. 

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
