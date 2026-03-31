#!/bin/bash

set -exuo pipefail

trap 'FRC=$?; [[ $FRC != 0 ]] && debug' EXIT TERM

debug() {
  oc get --namespace=local-cluster hostedcluster/${CLUSTER_NAME} -o yaml || true
  oc get pod -n local-cluster-${CLUSTER_NAME} -oyaml || true
  oc logs -n hypershift -lapp=operator --tail=-1 -c operator | grep -v "info" > $ARTIFACT_DIR/hypershift-errorlog.txt || true
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

HYPERSHIFT_NAME=hcp
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
echo "check HYPERSHIFT_HC_RELEASE_IMAGE, if not set, use mgmt-cluster payload image"
RELEASE_IMAGE=${HYPERSHIFT_HC_RELEASE_IMAGE:-$OCP_IMAGE_LATEST}

# Give IDMS priority over ICSP by appending the ICSP to the IDMS file.
if oc get imagedigestmirrorset &>/dev/null; then
  oc get imagedigestmirrorset -oyaml | yq '.items[].spec.imageDigestMirrors' > "${SHARED_DIR}/mgmt_icsp.yaml"
fi
if oc get imagecontentsourcepolicy &>/dev/null; then
  oc get imagecontentsourcepolicy -oyaml | yq '.items[].spec.repositoryDigestMirrors' >> "${SHARED_DIR}/mgmt_icsp.yaml"
fi

echo "$(date) Rendering HostedCluster YAML..."

# Render the HostedCluster YAML
/tmp/${HYPERSHIFT_NAME} create cluster agent \
  --name=${CLUSTER_NAME} \
  --pull-secret=/tmp/.dockerconfigjson \
  --agent-namespace=${AGENT_NAMESPACE} \
  --namespace local-cluster \
  --base-domain=${BASEDOMAIN} \
  --api-server-address=api.${CLUSTER_NAME}.${BASEDOMAIN} \
  --image-content-sources ${SHARED_DIR}/mgmt_icsp.yaml \
  --ssh-key=${SHARED_DIR}/id_rsa.pub \
  --release-image ${RELEASE_IMAGE} \
  --render > ${SHARED_DIR}/hostedcluster.yaml

echo "$(date) Modifying service publishing strategy to use Route for all services..."

# Modify the HostedCluster to use Route for all services
# This is necessary for Nutanix because DNS points to management cluster INGRESS_VIP
yq eval -i '
  (select(.kind == "HostedCluster") | .spec.services) = [
    {"service": "APIServer", "servicePublishingStrategy": {"type": "Route"}},
    {"service": "OAuthServer", "servicePublishingStrategy": {"type": "Route"}},
    {"service": "Konnectivity", "servicePublishingStrategy": {"type": "Route"}},
    {"service": "Ignition", "servicePublishingStrategy": {"type": "Route"}}
  ]
' ${SHARED_DIR}/hostedcluster.yaml

echo "$(date) Applying HostedCluster YAML..."
oc apply -f ${SHARED_DIR}/hostedcluster.yaml

echo "Waiting for cluster to become available"
oc wait --timeout=30m --for=condition=Available --namespace=local-cluster hostedcluster/${CLUSTER_NAME}

echo "Cluster became available, creating kubeconfig"
/tmp/${HYPERSHIFT_NAME} create kubeconfig --namespace=local-cluster --name=${CLUSTER_NAME} >${SHARED_DIR}/nested_kubeconfig
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"
