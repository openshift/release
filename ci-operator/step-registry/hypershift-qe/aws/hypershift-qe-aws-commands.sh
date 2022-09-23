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

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace="$NAMESPACE" "hostedcluster/$CLUSTER_NAME"
echo "Cluster became available, creating kubeconfig"
hypershift create kubeconfig --namespace="$NAMESPACE" --name="$CLUSTER_NAME" > "$SHARED_DIR/hostedcluster.kubeconfig"
echo "Waiting for clusteroperators to be ready"

until \
  oc wait --kubeconfig="$SHARED_DIR"/hostedcluster.kubeconfig --all=true clusteroperator --for='condition=Available=True' >/dev/null && \
  oc wait --kubeconfig="$SHARED_DIR"/hostedcluster.kubeconfig --all=true clusteroperator --for='condition=Progressing=False' >/dev/null && \
  oc wait --kubeconfig="$SHARED_DIR"/hostedcluster.kubeconfig --all=true clusteroperator --for='condition=Degraded=False' >/dev/null;  do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    sleep 1s
done

kubedamin_password=$(oc get secret -n "$NAMESPACE-$CLUSTER_NAME" kubeadmin-password -ojsonpath='{.data.password}')
echo $kubedamin_password > "$SHARED_DIR/hypershift_kubedamin_password"
cat "$SHARED_DIR/hypershift_kubedamin_password"
echo "https://$(oc --kubeconfig="$SHARED_DIR"/hostedcluster.kubeconfig -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "$SHARED_DIR/console.url"
cat "$SHARED_DIR/console.url"