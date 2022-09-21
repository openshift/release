#!/bin/bash

CLUSTER_NAME="ci-cluster"
NAMESPACE="clusters"

echo "extract secret/pull-secret"
oc extract secret/pull-secret -n openshift-config --to=config --confirm

echo "get playload image"
PLAYLOADIMAGE=$(oc get clusterversion version -ojsonpath='{.status.desired.image}')

echo "export-credentials"
accessKeyID=$(oc get secret -n kube-system aws-creds -o template='{{index .data "aws_access_key_id"|base64decode}}')
secureKey=$(oc get secret -n kube-system aws-creds -o template='{{index .data "aws_secret_access_key"|base64decode}}')
echo -e "[default]\naws_access_key_id=$accessKeyID\naws_secret_access_key=$secureKey" > config/awscredentials

REGION=$(oc get node -ojsonpath='{.items[].metadata.labels.topology\.kubernetes\.io/region}')
echo "region: $REGION"

PLAYLOADIMAGE=$(oc get clusterversion version -ojsonpath='{.status.desired.image}')
hypershift create cluster aws \
    --aws-creds config/awscredentials \
    --pull-secret config/.dockerconfigjson \
    --name "$CLUSTER_NAME" \
    --base-domain qe.devcluster.openshift.com \
    --namespace "$NAMESPACE" \
    --node-pool-replicas 3 \
    --region "$REGION" \
    --control-plane-availability-policy HighlyAvailable \
    --infra-availability-policy HighlyAvailable \
    --release-image "$PLAYLOADIMAGE"

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