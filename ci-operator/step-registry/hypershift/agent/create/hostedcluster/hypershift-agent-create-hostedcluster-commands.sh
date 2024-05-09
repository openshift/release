#!/bin/bash

set -exuo pipefail

oc annotate sc assisted-service storageclass.kubernetes.io/is-default-class=true

ICSP_COMMAND=""
if [[ $ENABLE_ICSP == "true" ]]; then
  ICSP_COMMAND=$(echo "--image-content-sources ${SHARED_DIR}/mgmt_icsp.yaml")
  echo "extract secret/pull-secret"
  oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
  if [ ! -f /tmp/yq-v4 ]; then
    curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
    -o /tmp/yq-v4 && chmod +x /tmp/yq-v4
  fi
  oc get imagecontentsourcepolicy -oyaml | /tmp/yq-v4 '.items[] | .spec.repositoryDigestMirrors' > "${SHARED_DIR}/mgmt_icsp.yaml"
fi

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "$(date) Creating HyperShift cluster ${CLUSTER_NAME}"
oc create ns "clusters-${CLUSTER_NAME}"
BASEDOMAIN=$(oc get dns/cluster -ojsonpath="{.spec.baseDomain}")
RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}
echo "extract secret/pull-secret"
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm

/usr/bin/hypershift create cluster agent ${ICSP_COMMAND} \
  --name=${CLUSTER_NAME} \
  --pull-secret=/tmp/.dockerconfigjson \
  --agent-namespace="clusters-${CLUSTER_NAME}" \
  --base-domain=${BASEDOMAIN} \
  --api-server-address=api.${CLUSTER_NAME}.${BASEDOMAIN} \
  --cluster-cidr fd03::/48 --service-cidr fd04::/112 \
  --additional-trust-bundle=${SHARED_DIR}/registry.2.crt \
  --olm-disable-default-sources \
  --release-image ${RELEASE_IMAGE}

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=clusters hostedcluster/${CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"
bin/hypershift create kubeconfig --namespace=clusters --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig