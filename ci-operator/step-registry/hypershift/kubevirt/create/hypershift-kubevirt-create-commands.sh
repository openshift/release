#!/bin/bash

set -exuo pipefail

HCP_CLI="/usr/bin/hcp"
if [[ ! -f $HCP_CLI ]]; then
  # we have to fall back to hypershift in cases where the new hcp cli isn't available yet
  HCP_CLI="/usr/bin/hypershift"
fi
echo "Using $HCP_CLI for cli"

RUN_HOSTEDCLUSTER_CREATION="${RUN_EXTERNAL_INFRA_TEST:-$RUN_HOSTEDCLUSTER_CREATION}"

if [ "${RUN_HOSTEDCLUSTER_CREATION}" != "true" ]
then
  echo "Creation of a kubevirt hosted cluster has been skipped."
  exit 0
fi

EXTRA_ARGS=""

if [ -n "${KUBEVIRT_CSI_INFRA}" ]
then
  EXTRA_ARGS="${EXTRA_ARGS} --infra-storage-class-mapping=${KUBEVIRT_CSI_INFRA}/${KUBEVIRT_CSI_INFRA}"
fi

if [ -n "${ETCD_STORAGE_CLASS}" ]
then
  EXTRA_ARGS="${EXTRA_ARGS} --etcd-storage-class=${ETCD_STORAGE_CLASS}"
fi

# Enable wildcard routes on the management cluster
oc patch ingresscontroller -n openshift-ingress-operator default --type=json -p \
  '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
CLUSTER_NAMESPACE=clusters-${CLUSTER_NAME}

echo "$(date) Creating HyperShift guest cluster ${CLUSTER_NAME}"
$HCP_CLI create cluster kubevirt \
  --name ${CLUSTER_NAME} \
  --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} \
  --memory ${HYPERSHIFT_NODE_MEMORY}Gi \
  --cores ${HYPERSHIFT_NODE_CPU_CORES} \
  --root-volume-size 64 \
  --pull-secret=/etc/ci-pull-credentials/.dockerconfigjson \
  --release-image ${RELEASE_IMAGE_LATEST} \
  ${EXTRA_ARGS}

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=clusters hostedcluster/${CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"
$HCP_CLI create kubeconfig --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig

if [ -n "${KUBEVIRT_CSI_INFRA}" ]
then
  for item in $(oc get sc --no-headers | awk '{print $1}'); do
  oc annotate --overwrite sc $item storageclass.kubernetes.io/is-default-class='false'
  done
  oc annotate --overwrite sc ${KUBEVIRT_CSI_INFRA} storageclass.kubernetes.io/is-default-class='true'
fi