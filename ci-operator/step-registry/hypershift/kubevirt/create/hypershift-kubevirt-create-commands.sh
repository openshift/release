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
    downURL=$(oc get ConsoleCLIDownload hcp-cli-download -o=jsonpath='{.spec.links[?(@.text=="Download hcp CLI for Linux for x86_64")].href}') && curl -k --output "/tmp/hcp.tar.gz" "${downURL}"
    cd /tmp && tar -xvf "/tmp/hcp.tar.gz"
    chmod +x "/tmp/hcp"
    HCP_CLI="/tmp/hcp"
    cd -
  fi
fi

function support_np_skew() {
  local EXTRA_FLARGS=""
  if [[ -n "$HOSTEDCLUSTER_RELEASE_IMAGE_LATEST" && -n "$NODEPOOL_RELEASE_IMAGE_LATEST" && -n "$MCE" && "$HOSTEDCLUSTER_RELEASE_IMAGE_LATEST" != "$NODEPOOL_RELEASE_IMAGE_LATEST" ]]; then
    curl -L "https://github.com/mikefarah/yq/releases/download/v4.31.2/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" -o /tmp/yq && chmod +x /tmp/yq
    # >= 2.7: "--render-sensitive --render", else: "--render"
    if [[ "$(printf '%s\n' "2.7" "$MCE_VERSION" | sort -V | head -n1)" == "2.7" ]]; then
      EXTRA_FLARGS+="--render-sensitive --render > /tmp/hc.yaml "
    else
      EXTRA_FLARGS+="--render > /tmp/hc.yaml "
    fi
    EXTRA_FLARGS+="&& /tmp/yq e -i '(select(.kind == \"NodePool\").spec.release.image) = \"$NODEPOOL_RELEASE_IMAGE_LATEST\"' /tmp/hc.yaml "
    EXTRA_FLARGS+="&& oc apply -f /tmp/hc.yaml"
  fi
  echo "$EXTRA_FLARGS"
}

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


RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}

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

  EXTRA_ARGS="${EXTRA_ARGS} --additional-trust-bundle=${SHARED_DIR}/registry.2.crt --annotations=hypershift.openshift.io/control-plane-operator-image=${HO_OPERATOR_IMAGE} --annotations=hypershift.openshift.io/olm-catalogs-is-registry-overrides=${OLM_CATALOGS_R_OVERRIDES}"

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

oc create namespace "${CLUSTER_NAMESPACE_PREFIX}" --dry-run=client -o yaml | oc apply -f -
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
    EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network=true --additional-network name:local-cluster-${CLUSTER_NAME}/macvlan-bridge-whereabouts"
  else
    EXTRA_ARGS="${EXTRA_ARGS} --attach-default-network=false --additional-network name:local-cluster-${CLUSTER_NAME}/macvlan-bridge-whereabouts"
  fi
fi

if [[ -f "${SHARED_DIR}/GPU_DEVICE_NAME" ]]; then
  EXTRA_ARGS="${EXTRA_ARGS} --host-device-name $(cat "${SHARED_DIR}/GPU_DEVICE_NAME"),count:2"
fi

EXTRA_ARGS="${EXTRA_ARGS} --network-type=${HYPERSHIFT_NETWORK_TYPE}"

echo "$(date) Creating HyperShift guest cluster ${CLUSTER_NAME}"
# Workaround for: https://issues.redhat.com/browse/OCPBUGS-42867
if [[ $HYPERSHIFT_CREATE_CLUSTER_RENDER == "true" ]]; then

  RENDER_COMMAND="--render --render-sensitive"
  OCP_MINOR_VERSION=$(oc version | grep "Server Version" | cut -d '.' -f2)
  if [ "$OCP_MINOR_VERSION" -le "16" ]; then
      RENDER_COMMAND="--render"
  fi

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
    --generate-ssh \
    --control-plane-availability-policy "${CONTROL_PLANE_AVAILABILITY}" \
    --infra-availability-policy "${INFRA_AVAILABILITY}" \
    --service-cidr 172.32.0.0/16 \
    --cluster-cidr 10.136.0.0/14 ${RENDER_COMMAND} > "${SHARED_DIR}/hypershift_create_cluster_render.yaml"

  oc apply -f "${SHARED_DIR}/hypershift_create_cluster_render.yaml"
else
  # shellcheck disable=SC2086
  eval "${HCP_CLI} create cluster kubevirt ${EXTRA_ARGS} ${ICSP_COMMAND} \
    --name ${CLUSTER_NAME} \
    --namespace ${CLUSTER_NAMESPACE_PREFIX} \
    --node-pool-replicas ${HYPERSHIFT_NODE_COUNT} \
    --memory ${HYPERSHIFT_NODE_MEMORY}Gi \
    --cores ${HYPERSHIFT_NODE_CPU_CORES} \
    --root-volume-size 64 \
    --release-image ${RELEASE_IMAGE} \
    --pull-secret ${PULL_SECRET_PATH} \
    --generate-ssh \
    --control-plane-availability-policy ${CONTROL_PLANE_AVAILABILITY} \
    --infra-availability-policy ${INFRA_AVAILABILITY} \
    --service-cidr 172.32.0.0/16 \
    --cluster-cidr 10.136.0.0/14  $(support_np_skew)"
fi



echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=${CLUSTER_NAMESPACE_PREFIX} "hostedcluster/${CLUSTER_NAME}"
echo "Cluster became available, creating kubeconfig"
$HCP_CLI create kubeconfig --namespace="${CLUSTER_NAMESPACE_PREFIX}" --name="${CLUSTER_NAME}" >"${SHARED_DIR}/nested_kubeconfig"

echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"
