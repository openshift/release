#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${LEASED_RESOURCE}
HOSTED_ZONE_ID=$(head -n 1 "${SHARED_DIR}/hosted_zone_id")

install_dir1=$(mktemp -d)
install_dir2=$(mktemp -d)

cp "${SHARED_DIR}/cluster-1-metadata.json" ${install_dir1}/metadata.json
cp "${SHARED_DIR}/cluster-2-metadata.json" ${install_dir2}/metadata.json

infra_id1=$(jq -r '.infraID' ${install_dir1}/metadata.json)
infra_id2=$(jq -r '.infraID' ${install_dir2}/metadata.json)


echo "Destroying cluster 1"
openshift-install destroy cluster --dir $install_dir1

echo "Destroying cluster 2"
openshift-install destroy cluster --dir $install_dir2


# "shared" tags were removed
ret=0
aws --region $REGION route53 list-tags-for-resource --resource-type hostedzone --resource-id "${HOSTED_ZONE_ID}" | jq -r '.ResourceTagSet.Tags | from_entries' > ${ARTIFACT_DIR}/phz_tags.json

if grep -qE "kubernetes.io/cluster/${infra_id1}.*shared" ${ARTIFACT_DIR}/phz_tags.json; then
  echo "ERROR: ${HOSTED_ZONE_ID}: FOUND tag kubernetes.io/cluster/${infra_id1}:shared"
  ret=$((ret+1))
else
  echo "PASS: ${HOSTED_ZONE_ID}: Not found tag kubernetes.io/cluster/${infra_id1}:shared"
fi

if grep -qE "kubernetes.io/cluster/${infra_id2}.*shared" ${ARTIFACT_DIR}/phz_tags.json; then
  echo "ERROR: ${HOSTED_ZONE_ID}: FOUND tag kubernetes.io/cluster/${infra_id2}:shared"
  ret=$((ret+1))
else
  echo "PASS: ${HOSTED_ZONE_ID}: Not found tag kubernetes.io/cluster/${infra_id2}:shared"
fi

exit $ret
