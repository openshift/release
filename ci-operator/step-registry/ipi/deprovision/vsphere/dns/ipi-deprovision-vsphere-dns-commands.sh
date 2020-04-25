#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
export AWS_SHARED_CREDENTIALS_FILE=${cluster_profile}/.awscred 

HOSTED_ZONE_ID="$(cat "${SHARED_DIR}/hosted-zone.txt")"

id=$(aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "file:///${SHARED_DIR}/dns-delete.json" --query '"ChangeInfo"."Id"' --output text)

echo "Waiting for Route53 DNS records to be deleted..."

aws route53 wait resource-record-sets-changed --id "$id"

echo "Delete successful."
