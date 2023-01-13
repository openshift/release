#!/usr/bin/env bash
set -euo pipefail

echo "Set KUBECONFIG to Hive cluster"
export KUBECONFIG=/var/run/hypershift-workload-credentials/kubeconfig

HOSTED_CLUSTER_FILE="$SHARED_DIR/hosted_cluster.txt"
if [ -f "$HOSTED_CLUSTER_FILE" ]; then
  echo "Loading $HOSTED_CLUSTER_FILE"
  # shellcheck source=/dev/null
  source "$HOSTED_CLUSTER_FILE"
  echo "Loaded $HOSTED_CLUSTER_FILE"
  echo "Cluster name: $CLUSTER_NAME"
else
  CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
  echo "$HOSTED_CLUSTER_FILE does not exist. Defaulting to the default cluster name: $CLUSTER_NAME."
fi

bin/hypershift dump cluster --artifact-dir=$ARTIFACT_DIR \
--dump-guest-cluster=true \
--name="${CLUSTER_NAME}"
