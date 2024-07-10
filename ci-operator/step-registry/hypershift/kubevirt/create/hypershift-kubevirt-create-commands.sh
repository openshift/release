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
  arch=$(arch)
  if [ "$arch" == "x86_64" ]; then
    if (( $(awk 'BEGIN {print ("'"$MCE_VERSION"'" < 2.4)}') )); then
      echo "MCE version is less than 2.4, use hypershift command"
      downURL=$(oc get ConsoleCLIDownload hypershift-cli-download -o=jsonpath='{.spec.links[?(@.text=="Download hypershift CLI for Linux for x86_64")].href}') && curl -k --output "/tmp/hypershift.tar.gz" "${downURL}"
      cd /tmp && tar -xvf "/tmp/hypershift.tar.gz"
      chmod +x "/tmp/hypershift"
      HCP_CLI="/tmp/hypershift"
      cd -
    else
      downURL=$(oc get ConsoleCLIDownload hcp-cli-download -o=jsonpath='{.spec.links[?(@.text=="Download hcp CLI for Linux for x86_64")].href}') && curl -k --output "/tmp/hcp.tar.gz" "${downURL}"
      cd /tmp && tar -xvf "/tmp/hcp.tar.gz"
      chmod +x "/tmp/hcp"
      HCP_CLI="/tmp/hcp"
      cd -
    fi
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
  if [ ! -f /tmp/yq-v4 ]; then
    curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
    -o /tmp/yq-v4 && chmod +x /tmp/yq-v4
  fi
  oc get imagecontentsourcepolicy -oyaml | /tmp/yq-v4 '.items[] | .spec.repositoryDigestMirrors' > "${SHARED_DIR}/mgmt_icsp.yaml"
fi

# Enable wildcard routes on the management cluster
oc patch ingresscontroller -n openshift-ingress-operator default --type=json -p \
  '[{ "op": "add", "path": "/spec/routeAdmission", "value": {wildcardPolicy: "WildcardsAllowed"}}]'


RELEASE_IMAGE="${RELEASE_IMAGE_LATEST}"

if [[ "${DISCONNECTED}" == "true" ]];
then
  mirror_registry=$(oc get imagecontentsourcepolicy cnv-repo -o=jsonpath='{.spec.repositoryDigestMirrors[0].mirrors[0]}')
  mirror_registry=${mirror_registry%%/*}
  if [[ $mirror_registry == "" ]] ; then
      echo "Warning: Can not find the mirror registry, abort !!!"
      exit 1
  fi
  echo "mirror registry is ${mirror_registry}"

  mirrored_index=${mirror_registry}/olm-index/redhat-operator-index
  OLM_CATALOGS_R_OVERRIDES=registry.redhat.io/redhat/certified-operator-index=${mirrored_index},registry.redhat.io/redhat/community-operator-index=${mirrored_index},registry.redhat.io/redhat/redhat-marketplace-index=${mirrored_index},registry.redhat.io/redhat/redhat-operator-index=${mirrored_index}

  PAYLOADIMAGE=$(oc get clusterversion version -ojsonpath='{.status.desired.image}')
  RELEASE_IMAGE="${PAYLOADIMAGE}"

  if [ ! -f "${SHARED_DIR}/ho_operator_image" ] ; then
      echo "Warning: Can not find ho_operator_image, abort !!!"
      exit 1
  fi
  HO_OPERATOR_IMAGE=$(cat "${SHARED_DIR}/ho_operator_image")

  EXTRA_ARGS="${EXTRA_ARGS} --additional-trust-bundle=${SHARED_DIR}/registry.2.crt --network-type=OVNKubernetes --annotations=hypershift.openshift.io/control-plane-operator-image=${HO_OPERATOR_IMAGE} --annotations=hypershift.openshift.io/olm-catalogs-is-registry-overrides=${OLM_CATALOGS_R_OVERRIDES}"

  ### workaround for https://issues.redhat.com/browse/OCPBUGS-32770
  if [[ -z ${MCE} ]] ; then
    if [ ! -f "${SHARED_DIR}/capi_provider_kubevirt_image" ] ; then
        echo "Warning: Can not find capi_provider_kubevirt_image, abort !!!"
        exit 1
    fi
    CAPI_PROVIDER_KUBEVIRT_IMAGE=$(cat "${SHARED_DIR}/capi_provider_kubevirt_image")

    EXTRA_ARGS="${EXTRA_ARGS} --annotations=hypershift.openshift.io/capi-provider-kubevirt-image=${CAPI_PROVIDER_KUBEVIRT_IMAGE}"
  fi
  ###

fi

oc create ns "${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}"
if [[ -n "${ATTACH_DEFAULT_NETWORK}" ]]; then
  oc apply -f - <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-bridge-whereabouts
  namespace: ${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}
spec:
  config: '{
      "cniVersion": "0.3.1",
      "name": "whereabouts",
      "type": "macvlan",
      "master": "enp3s0",
      "mode": "bridge",
      "ipam": {
        "type": "whereabouts",
        "range": "192.168.221.0/24"
      }
  }'
EOF
  if [[ "${ATTACH_DEFAULT_NETWORK}" == "true" ]]; then
    EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network true --additional-network name:local-cluster-${CLUSTER_NAME}/macvlan-bridge-whereabouts"
  else
    EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network false --additional-network name:local-cluster-${CLUSTER_NAME}/macvlan-bridge-whereabouts"
  fi
fi


echo "$(date) Creating HyperShift guest cluster ${CLUSTER_NAME}"
# shellcheck disable=SC2086
"${HCP_CLI}" create cluster kubevirt ${EXTRA_ARGS} ${ICSP_COMMAND} \
  --name "${CLUSTER_NAME}" \
  --namespace "${CLUSTER_NAMESPACE_PREFIX}" \
  --node-pool-replicas "${HYPERSHIFT_NODE_COUNT}" \
  --memory "${HYPERSHIFT_NODE_MEMORY}Gi" \
  --cores "${HYPERSHIFT_NODE_CPU_CORES}" \
  --root-volume-size 64 \
  --release-image "${RELEASE_IMAGE}" \
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
