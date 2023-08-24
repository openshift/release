#!/usr/bin/env bash
set -euox pipefail

echo "Set KUBECONFIG to Hive cluster"
export KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig

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

echo "$(date) Deleting HyperShift cluster ${CLUSTER_NAME}"

bin/hypershift destroy cluster powervs \
  --name ${CLUSTER_NAME} \
  --infra-id ${INFRA_ID} \
  --region ${POWERVS_REGION} \
  --zone ${POWERVS_ZONE} \
  --vpc-region ${POWERVS_VPC_REGION} \
  --resource-group ${POWERVS_RESOURCE_GROUP} \
  --base-domain ${BASE_DOMAIN} \
  --cloud-instance-id ${POWERVS_GUID} \
  --vpc ${VPC} \
  --cloud-connection ${CLOUD_CONNECTION} \
  --cluster-grace-period 40m
echo "$(date) Finished deleting cluster"