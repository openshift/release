#!/bin/bash
#
# Drop xpn.json into SHARED_DIR so that upi-conf-gcp and upi-install-gcp
# know to configure a Shared VPC (XPN). This requires the following:
#
# - A HOST_PROJECT sharing two XPN subnets with openshift-gce-devel-ci.
# - Firewall rules configured in the HOST_PROJECT VPC based on 03_security_firewall.yaml
#   - All sources and targets need to use network_cidr instead of infra_id
# - A DNS zone configured in the HOST_PROJECT attached to the VPC
#   - origin-ci-int-gce.dev.openshift.com
# - IAM roles in the HOST_PROJECT
#   - The openshift-gce-devel-ci service account (1053217076791@cloudservices.gserviceaccount.com)
#     - Compute Network User
#   - ${CLUSTER_PROFILE_DIR}/gce.json (do-not-delete-ci-provisioner@openshift-gce-devel-ci.iam.gserviceaccount.com)
#     - Compute Network User on both XPN Subnets (https://console.cloud.google.com/networking/xpn)
#     - Deployment Manager Editor
#     - DNS Administrator on the
#   - ${COMPUTE_SERVICE_ACCOUNT} (defined below)
#     - Compute Network User on both XPN Subnets (https://console.cloud.google.com/networking/xpn)
#   - ${CONTROL_SERVICE_ACCOUNT} (defined below)
#     - Compute Network User on both XPN Subnets (https://console.cloud.google.com/networking/xpn)
#     - Compute Network Viewer in HOST PROJECT
set -o nounset
set -o errexit
set -o pipefail

HOST_PROJECT="openshift-dev-installer"
CLUSTER_NETWORK="https://www.googleapis.com/compute/v1/projects/openshift-dev-installer/global/networks/installer-shared-vpc"
CONTROL_SUBNET="https://www.googleapis.com/compute/v1/projects/openshift-dev-installer/regions/us-east1/subnetworks/installer-shared-vpc-subnet-1"
COMPUTE_SUBNET="https://www.googleapis.com/compute/v1/projects/openshift-dev-installer/regions/us-east1/subnetworks/installer-shared-vpc-subnet-2"
COMPUTE_SERVICE_ACCOUNT="do-not-delete-ci-xpn@openshift-gce-devel-ci.iam.gserviceaccount.com"
CONTROL_SERVICE_ACCOUNT="do-not-delete-ci-xpn@openshift-gce-devel-ci.iam.gserviceaccount.com"
PRIVATE_ZONE_NAME="ci-op-xpn-private-zone"

cat > "${SHARED_DIR}/xpn.json" << EOF
{
    "hostProject": "${HOST_PROJECT}",
    "clusterNetwork": "${CLUSTER_NETWORK}",
    "computeSubnet": "${COMPUTE_SUBNET}",
    "controlSubnet": "${CONTROL_SUBNET}",
    "computeServiceAccount": "${COMPUTE_SERVICE_ACCOUNT}",
    "controlServiceAccount": "${CONTROL_SERVICE_ACCOUNT}",
    "privateZoneName": "${PRIVATE_ZONE_NAME}"
}
EOF
