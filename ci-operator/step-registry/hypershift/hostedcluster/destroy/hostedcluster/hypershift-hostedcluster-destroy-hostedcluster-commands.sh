#!/usr/bin/env bash
set -euox pipefail

echo "Set KUBECONFIG to Hive cluster"
export KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig

AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ ! -f "${AWS_GUEST_INFRA_CREDENTIALS_FILE}" ]]; then
  echo "AWS credentials file ${AWS_GUEST_INFRA_CREDENTIALS_FILE} not found"
  exit 1
fi

DEFAULT_BASE_DOMAIN=ci.hypershift.devcluster.openshift.com

if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
  AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  DEFAULT_BASE_DOMAIN=origin-ci-int-aws.dev.rhcloud.com
fi
DOMAIN=${HYPERSHIFT_BASE_DOMAIN:-$DEFAULT_BASE_DOMAIN}

HOSTED_CLUSTER_FILE="$SHARED_DIR/hosted_cluster.txt"
if [ -f "$HOSTED_CLUSTER_FILE" ]; then
  echo "Loading $HOSTED_CLUSTER_FILE"
  # shellcheck source=/dev/null
  source "$HOSTED_CLUSTER_FILE"
  echo "Loaded $HOSTED_CLUSTER_FILE"
  echo "Cluster name: $CLUSTER_NAME, infra ID: $INFRA_ID"
else
  CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
  INFRA_ID=""
  echo "$HOSTED_CLUSTER_FILE does not exist. Defaulting to the default cluster name: $CLUSTER_NAME."
fi

createdAt=`oc -n clusters get hostedclusters $CLUSTER_NAME -o jsonpath='{.metadata.annotations.created-at}'`
if [ -z $createdAt ]; then
  echo Cluster is broken, skipping...
  oc annotate -n clusters hostedcluster ${CLUSTER_NAME} "broken=true"
  exit 0
fi
echo Cluster successfully created at $createdAt

echo "$(date) Deleting HyperShift cluster ${CLUSTER_NAME}"

for _ in {1..10}; do
  bin/hypershift destroy cluster aws \
    --aws-creds=${AWS_GUEST_INFRA_CREDENTIALS_FILE}  \
    --name ${CLUSTER_NAME} \
    --infra-id ${INFRA_ID} \
    --region ${HYPERSHIFT_AWS_REGION} \
    --base-domain ${DOMAIN} \
    --cluster-grace-period 40m
  if [ $? == 0 ]; then
    break
  else
    echo 'Failed to delete the cluster, retrying...'
  fi
done
echo "$(date) Finished deleting cluster"
