#!/bin/bash

set -exuo pipefail

oc annotate sc assisted-service storageclass.kubernetes.io/is-default-class=true

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "$(date) Creating HyperShift cluster ${CLUSTER_NAME}"
oc create ns "clusters-${CLUSTER_NAME}"
BASEDOMAIN=$(oc get dns/cluster -ojsonpath="{.spec.baseDomain}")
RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}
echo "extract secret/pull-secret"
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm

/usr/bin/hypershift create cluster agent \
  --name=${CLUSTER_NAME} \
  --pull-secret=/tmp/.dockerconfigjson \
  --agent-namespace="clusters-${CLUSTER_NAME}" \
  --base-domain=${BASEDOMAIN} \
  --api-server-address=api.${CLUSTER_NAME}.${BASEDOMAIN} \
  --release-image ${RELEASE_IMAGE}

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=clusters hostedcluster/${CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"
bin/hypershift create kubeconfig --namespace=clusters --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig