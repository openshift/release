#!/bin/bash

set -xeuo pipefail

CLUSTER_NAME="ci-cluster"
NAMESPACE="clusters"

echo "extract secret/pull-secret"
oc extract secret/pull-secret -n openshift-config --to="$SHARED_DIR" --confirm
echo "get playload image"
playloadimage=$(oc get clusterversion version -ojsonpath='{.status.desired.image}')
region=$(oc get node -ojsonpath='{.items[].metadata.labels.topology\.kubernetes\.io/region}')
echo "region: $region"

hypershift create cluster aws \
    --aws-creds "$SHARED_DIR/awscredentials" \
    --pull-secret "$SHARED_DIR/.dockerconfigjson" \
    --name "$CLUSTER_NAME" \
    --base-domain qe.devcluster.openshift.com \
    --namespace "$NAMESPACE" \
    --node-pool-replicas 3 \
    --region "$region" \
    --control-plane-availability-policy HighlyAvailable \
    --infra-availability-policy HighlyAvailable \
    --release-image "$playloadimage"

#export KUBECONFIG=${SHARED_DIR}/management_cluster_kubeconfig
#until \
#  oc wait --all=true clusteroperator --for='condition=Available=True' >/dev/null && \
#  oc wait --all=true clusteroperator --for='condition=Progressing=False' >/dev/null && \
#  oc wait --all=true clusteroperator --for='condition=Degraded=False' >/dev/null;  do
#    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
#    sleep 1s
#done
## Data for cluster bot.
#echo "https://$(oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"