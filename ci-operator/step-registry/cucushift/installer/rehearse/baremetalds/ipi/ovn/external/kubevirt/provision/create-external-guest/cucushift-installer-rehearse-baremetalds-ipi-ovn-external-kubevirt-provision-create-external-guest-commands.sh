#!/bin/bash

set -exuo pipefail

# Target: management cluster - creating Cluster B (KubeVirt HCP with external infra)
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: Management cluster kubeconfig not found at ${SHARED_DIR}/kubeconfig"
  exit 1
fi
if [[ ! -f "${SHARED_DIR}/external_infra_kubeconfig" ]]; then
  echo "ERROR: External infra kubeconfig not found at ${SHARED_DIR}/external_infra_kubeconfig"
  exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Download hcp CLI from MCE's ConsoleCLIDownload
HYPERSHIFT_NAME=hcp
arch=$(arch)
if [ "$arch" == "x86_64" ]; then
  downURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href') && curl -k --output /tmp/${HYPERSHIFT_NAME}.tar.gz ${downURL}
  cd /tmp && tar -xvf /tmp/${HYPERSHIFT_NAME}.tar.gz
  chmod +x /tmp/${HYPERSHIFT_NAME}
  cd -
fi
HCP_CLI="/tmp/${HYPERSHIFT_NAME}"

# Use a different cluster name for Cluster B to avoid collision with Cluster A
CLUSTER_NAME="$(echo -n "${PROW_JOB_ID}-ext"|sha256sum|cut -c-20)"
CLUSTER_NAMESPACE=local-cluster

RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}
PULL_SECRET_PATH="/etc/ci-pull-credentials/.dockerconfigjson"

EXTRA_ARGS=""

if [ -n "${ETCD_STORAGE_CLASS}" ]; then
  EXTRA_ARGS="${EXTRA_ARGS} --etcd-storage-class=${ETCD_STORAGE_CLASS}"
fi

EXTRA_ARGS="${EXTRA_ARGS} --infra-kubeconfig-file=${SHARED_DIR}/external_infra_kubeconfig"
EXTRA_ARGS="${EXTRA_ARGS} --infra-namespace=${EXTERNAL_INFRA_NS}"

# Enable wildcard routes on the management cluster
oc patch ingresscontroller -n openshift-ingress-operator default --type=json -p \
  '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'

oc create namespace "${CLUSTER_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
oc create ns "${CLUSTER_NAMESPACE}-${CLUSTER_NAME}" --dry-run=client -o yaml | oc apply -f -

EXTRA_ARGS="${EXTRA_ARGS} --network-type=OVNKubernetes"
EXTRA_ARGS="${EXTRA_ARGS} --service-cidr 172.32.0.0/16 --cluster-cidr 10.136.0.0/14"

echo "$(date) Creating external infra HyperShift guest cluster ${CLUSTER_NAME}"
# shellcheck disable=SC2086
eval "${HCP_CLI} create cluster kubevirt ${EXTRA_ARGS} \
  --name ${CLUSTER_NAME} \
  --namespace ${CLUSTER_NAMESPACE} \
  --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} \
  --memory ${HYPERSHIFT_NODE_MEMORY}Gi \
  --cores ${HYPERSHIFT_NODE_CPU_CORES} \
  --root-volume-size 64 \
  --release-image ${RELEASE_IMAGE} \
  --pull-secret ${PULL_SECRET_PATH} \
  --generate-ssh \
  --control-plane-availability-policy SingleReplica \
  --infra-availability-policy SingleReplica"

echo "Waiting for external infra cluster to become available"
oc wait --timeout=40m --for=condition=Available --namespace="${CLUSTER_NAMESPACE}" "hostedcluster/${CLUSTER_NAME}"
echo "External infra cluster became available, creating kubeconfig"
$HCP_CLI create kubeconfig --namespace="${CLUSTER_NAMESPACE}" --name="${CLUSTER_NAME}" > "${SHARED_DIR}/external_guest_kubeconfig"

echo "${CLUSTER_NAME}" > "${SHARED_DIR}/external-cluster-name"

echo "Waiting for external infra cluster nodes to be ready"
EXPECTED_NODES="${HYPERSHIFT_NODE_COUNT}"
until [[ $(oc --kubeconfig="${SHARED_DIR}/external_guest_kubeconfig" get nodes --no-headers 2>/dev/null | wc -l) -ge ${EXPECTED_NODES} ]]; do
  echo "$(date --rfc-3339=seconds) Waiting for ${EXPECTED_NODES} nodes to appear..."
  sleep 30
done

echo "Waiting for cluster operators to be ready"
oc --kubeconfig="${SHARED_DIR}/external_guest_kubeconfig" wait clusterversion/version --for='condition=Available=True' --timeout=40m

echo "=== External infra guest cluster ${CLUSTER_NAME} is ready ==="
echo "Nodes:"
oc --kubeconfig="${SHARED_DIR}/external_guest_kubeconfig" get nodes -o wide
echo ""
echo "Cluster Operators:"
oc --kubeconfig="${SHARED_DIR}/external_guest_kubeconfig" get clusteroperators
