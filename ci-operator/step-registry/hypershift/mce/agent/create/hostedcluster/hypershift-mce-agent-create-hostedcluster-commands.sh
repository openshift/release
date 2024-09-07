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

if [[ "${CLUSTER_TYPE}" == "equinix-ocp-metal-qe" ]]; then
  # This is a RDU2 lab cluster. RDU2 lab clusters deployed via step-registry/baremetal steps do not
  # rely on the IP_STACK variable to determine the IP stack configuration. Instead, the IP stack
  # configuration is determined by the two env variables ipv4_enabled and ipv6_enabled.
  # This code block is used to adapt this step to be compatible with both RDU2 lab clusters and
  # dev-scripts-based ones.
  echo "This is a RDU2 lab cluster"
  IP_STACK=""
  # shellcheck disable=SC2154
  if [ "$ipv4_enabled" == "true" ]; then
    echo "IPv4 is enabled"
    IP_STACK="v4"
  fi
  # shellcheck disable=SC2154
  if [ "$ipv6_enabled" == "true" ]; then
    echo "IPv6 is enabled"
    IP_STACK="${IP_STACK}v6"
  fi
fi
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

if [ ! -f "${SHARED_DIR}/id_rsa.pub" ] && [ -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]; then
  cp "${CLUSTER_PROFILE_DIR}/ssh-publickey" "${SHARED_DIR}/id_rsa.pub"
fi

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

# This is only needed for the RDU2 clusters, but harmless to execute for all cases.
# They are backed by an HAProxy load balancer in a public (to VPN users) network.
# Hosts, instead, are in a private network. The load balancer will forward the traffic from the public network to:
# - any of the 3 management clusters worker nodes for the kube API server, ignition and oauth.
#   the ports are written to the shared dir for the haproxy config generation that runs after this step.
# - any of the 2 hosted clusters worker nodes for the ingress. We fix the port to 30443 and 30080.
# - the other services, mcs/ignition in particular, should support the route strategy.
for service in kube-apiserver ignition-server-proxy oauth-openshift konnectivity-server; do
  while ! oc get service -n "local-cluster-${CLUSTER_NAME}" $service; do
    echo "The $service service does not exist yet."
    sleep 10
  done
  oc get service -n "local-cluster-${CLUSTER_NAME}" \
    "${service}" -o jsonpath='{.spec.ports[0].nodePort}' > "$SHARED_DIR/hosted_${service}_port"
done

echo "Cluster became available, creating kubeconfig"
/tmp/${HYPERSHIFT_NAME} create kubeconfig --namespace=local-cluster --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig
