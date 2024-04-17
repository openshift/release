#!/bin/bash

set -exuo pipefail

HCP_CLI="/usr/bin/hcp"

MCE=${MCE_VERSION:-""}
CLUSTER_NAME=$(echo -n "${PROW_JOB_ID}"|sha256sum|cut -c-20)
if [[ -n ${MCE} ]] ; then
    CLUSTER_NAMESPACE_PREFIX=local-cluster
else
    CLUSTER_NAMESPACE_PREFIX=clusters
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    # shellcheck source=/dev/null
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -n ${MCE} ]] ; then
  HYPERSHIFT_NAME=hcp
  if (( $(awk 'BEGIN {print ("'"$MCE_VERSION"'" < 2.4)}') )); then
    echo "MCE version is less than 2.4, use hypershift command"
    HYPERSHIFT_NAME=hypershift
  fi

  arch=$(arch)
  if [ "$arch" == "x86_64" ]; then
    downURL=$(oc get ConsoleCLIDownload hcp-cli-download -o=jsonpath='{.spec.links[?(@.text=="Download hcp CLI for Linux for x86_64")].href}') && curl -k --output "/tmp/${HYPERSHIFT_NAME}.tar.gz" "${downURL}"
    cd /tmp && tar -xvf "/tmp/${HYPERSHIFT_NAME}.tar.gz"
    chmod +x "/tmp/${HYPERSHIFT_NAME}"
    HCP_CLI="/tmp/${HYPERSHIFT_NAME}"
    cd -
  fi
fi


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

if [ "$(oc get infrastructure cluster -o=jsonpath='{.status.platformStatus.type}')" == "AWS" ]; then
  if [ -z "$ETCD_STORAGE_CLASS" ]; then
    echo "AWS infra detected. Setting --etcd-storage-class"
    ETCD_STORAGE_CLASS="gp3-csi"
  fi
fi

if [ -n "${ETCD_STORAGE_CLASS}" ]
then
  EXTRA_ARGS="${EXTRA_ARGS} --etcd-storage-class=${ETCD_STORAGE_CLASS}"
fi

PULL_SECRET_PATH="/etc/ci-pull-credentials/.dockerconfigjson"
ICSP_COMMAND=""
if [[ $ENABLE_ICSP == "true" ]]; then
  ICSP_COMMAND=$(echo "--image-content-sources ${SHARED_DIR}/mgmt_icsp.yaml")
  echo "extract secret/pull-secret"
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  PULL_SECRET_PATH="/tmp/.dockerconfigjson"
fi

# Enable wildcard routes on the management cluster
oc patch ingresscontroller -n openshift-ingress-operator default --type=json -p \
  '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'


echo "$(date) Creating HyperShift guest cluster ${CLUSTER_NAME}"
# shellcheck disable=SC2086
"${HCP_CLI}" create cluster kubevirt ${EXTRA_ARGS} ${ICSP_COMMAND} \
  --name "${CLUSTER_NAME}" \
  --namespace "${CLUSTER_NAMESPACE_PREFIX}" \
  --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}" \
  --memory "${HYPERSHIFT_NODE_MEMORY}Gi" \
  --cores "${HYPERSHIFT_NODE_CPU_CORES}" \
  --root-volume-size 64 \
  --release-image "${RELEASE_IMAGE_LATEST}" \
  --pull-secret "${PULL_SECRET_PATH}" \
  --generate-ssh

if [[ -n ${MCE} ]] ; then
  if (( $(awk 'BEGIN {print ("'"$MCE_VERSION"'" < 2.4)}') )); then
    oc annotate hostedclusters -n "${CLUSTER_NAMESPACE_PREFIX}" "${CLUSTER_NAME}" "cluster.open-cluster-management.io/managedcluster-name=${CLUSTER_NAME}" --overwrite
    oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  annotations:
    import.open-cluster-management.io/hosting-cluster-name: local-cluster
    import.open-cluster-management.io/klusterlet-deploy-mode: Hosted
    open-cluster-management/created-via: other
  labels:
    cloud: auto-detect
    cluster.open-cluster-management.io/clusterset: default
    name: ${CLUSTER_NAME}
    vendor: OpenShift
  name: ${CLUSTER_NAME}
spec:
  hubAcceptsClient: true
  leaseDurationSeconds: 60
EOF
  fi
fi


echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=${CLUSTER_NAMESPACE_PREFIX} "hostedcluster/${CLUSTER_NAME}"
echo "Cluster became available, creating kubeconfig"
$HCP_CLI create kubeconfig --namespace="${CLUSTER_NAMESPACE_PREFIX}" --name="${CLUSTER_NAME}" >"${SHARED_DIR}/nested_kubeconfig"

if [ -n "${KUBEVIRT_CSI_INFRA}" ]
then
  for item in $(oc get sc --no-headers | awk '{print $1}'); do
  oc annotate --overwrite sc "${item}" storageclass.kubernetes.io/is-default-class='false'
  done
  oc annotate --overwrite sc "${KUBEVIRT_CSI_INFRA}" storageclass.kubernetes.io/is-default-class='true'
fi
