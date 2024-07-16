#!/bin/bash

set -exuo pipefail

trap 'FRC=$?; [[ $FRC != 0 ]] && debug' EXIT TERM

debug() {
  oc get --namespace=local-cluster hostedcluster/${CLUSTER_NAME} -o yaml
  oc get pod -n local-cluster-${CLUSTER_NAME} -oyaml
  oc logs -n hypershift -lapp=operator --tail=-1 -c operator | grep -v "info" > $ARTIFACT_DIR/hypershift-errorlog.txt
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

MCE_VERSION=$(oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
HYPERSHIFT_NAME=hcp
if (( $(awk 'BEGIN {print ("'"$MCE_VERSION"'" < 2.4)}') )); then
  echo "MCE version is less than 2.4"
  HYPERSHIFT_NAME=hypershift
fi

arch=$(arch)
if [ "$arch" == "x86_64" ]; then
  downURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href') && curl -k --output /tmp/${HYPERSHIFT_NAME}.tar.gz ${downURL}
  cd /tmp && tar -xvf /tmp/${HYPERSHIFT_NAME}.tar.gz
  chmod +x /tmp/${HYPERSHIFT_NAME}
  cd -
fi

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
if [[ -z ${AGENT_NAMESPACE} ]] ; then
  AGENT_NAMESPACE=local-cluster-${CLUSTER_NAME}
fi
oc get ns "${AGENT_NAMESPACE}" || oc create namespace "${AGENT_NAMESPACE}"
echo "$(date) Creating HyperShift cluster ${CLUSTER_NAME}"
BASEDOMAIN=$(oc get dns/cluster -ojsonpath="{.spec.baseDomain}")
echo "extract secret/pull-secret"
oc extract secret/pull-secret -n openshift-config --to=/tmp --confirm
echo "check HYPERSHIFT_HC_RELEASE_IMAGE, if not set, use mgmt-cluster playload image"
RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$RELEASE_IMAGE_LATEST}

case "${IP_STACK}" in
  "v4v6")
    # --cluster-cidr 10.132.0.0/14 --cluster-cidr fd03::/48 --service-cidr 172.31.0.0/16 --service-cidr fd04::/112
    EXTRA_ARGS+="--default-dual"
    ;;
  "v6")
    EXTRA_ARGS+="--cluster-cidr fd03::/48 --service-cidr fd04::/112 "
    ;;
esac

if [[ "$DISCONNECTED" == "true" ]]; then
  source "${SHARED_DIR}/packet-conf.sh"
  # disconnected requires the additional trust bundle containing the local registry certificate
  scp "${SSHOPTS[@]}" "root@${IP}:/etc/pki/ca-trust/source/anchors/registry.2.crt" "${SHARED_DIR}/registry.2.crt"
  EXTRA_ARGS+=" --additional-trust-bundle=${SHARED_DIR}/registry.2.crt --network-type=OVNKubernetes "
  EXTRA_ARGS+=" --olm-disable-default-sources "
  RELEASE_IMAGE=$(oc get clusterversion version -ojsonpath='{.status.desired.image}')
fi

/tmp/${HYPERSHIFT_NAME} --version
/tmp/${HYPERSHIFT_NAME} create cluster agent ${EXTRA_ARGS} \
  --name=${CLUSTER_NAME} \
  --pull-secret=/tmp/.dockerconfigjson \
  --agent-namespace="${AGENT_NAMESPACE}" \
  --namespace local-cluster \
  --base-domain=${BASEDOMAIN} \
  --api-server-address=api.${CLUSTER_NAME}.${BASEDOMAIN} \
  --image-content-sources "${SHARED_DIR}/mgmt_icsp.yaml" \
  --ssh-key="${SHARED_DIR}/id_rsa.pub" \
  --release-image ${RELEASE_IMAGE}

if (( $(awk 'BEGIN {print ("'"$MCE_VERSION"'" < 2.4)}') )); then
  echo "MCE version is less than 2.4"
  oc annotate hostedclusters -n local-cluster ${CLUSTER_NAME} "cluster.open-cluster-management.io/managedcluster-name=${CLUSTER_NAME}" --overwrite
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

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=local-cluster hostedcluster/${CLUSTER_NAME}
echo "Cluster became available, creating kubeconfig"
/tmp/${HYPERSHIFT_NAME} create kubeconfig --namespace=local-cluster --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig