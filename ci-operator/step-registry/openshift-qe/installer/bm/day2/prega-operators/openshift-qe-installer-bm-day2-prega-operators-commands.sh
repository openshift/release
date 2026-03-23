#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

PREGA_BUILD_SERVER_IP=$(cat ${CLUSTER_PROFILE_DIR}/prega_build_server)
SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)

get_idms_manifest() {
  echo "Getting the ImageDigestMirrorSet manifest from the PREGA build server"
  QUAY_URL="https://quay.io/api/v1/repository/prega/prega-operator-index/tag/?limit=100&page=1"
  OCP_VERSION=$(oc get clusterversion --no-headers | grep -o '[4].[0-9][0-9]' | head -1 | awk '{print "v"$0}')
  DIGEST=$(curl -s ${QUAY_URL} | jq -r --arg tag "$OCP_VERSION" '.tags[] | select(.name == $tag) | .manifest_digest' | head -1)
  OPERATOR_PREGA_VERSION=$(curl -s ${QUAY_URL} | jq -r --arg digest "$DIGEST" --arg tag "$OCP_VERSION" '.tags[] | select(.manifest_digest == $digest and .name != $tag) | .name' | sort -u)
  echo "PREGA Operator Version: ${OPERATOR_PREGA_VERSION} for OCP Version: ${OCP_VERSION}"
  ssh ${SSH_ARGS} root@${bastion} "
    set -e
    set -o pipefail
    curl -o /tmp/idms.yaml http://${PREGA_BUILD_SERVER_IP}/${OPERATOR_PREGA_VERSION}/imageDigestMirrorSet.yaml
  "
  scp -q ${SSH_ARGS} root@${bastion}:/tmp/idms.yaml /tmp/idms.yaml
  echo "ImageDigestMirrorSet manifest saved to /tmp/idms.yaml"
}

oc config view
oc projects

if [ ${OCP_BUILD} == "dev" ]; then
  echo "Patching OperatorHub to disable all default sources"
  oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

  echo "Getting the existing pull secret from the cluster and merge the prega_auth secret to pull images from quay.io"
  oc get secret pull-secret -n openshift-config -o json | jq -r '.data[".dockerconfigjson"]' | base64 -d > /tmp/existing_pull_secret.json
  cp ${CLUSTER_PROFILE_DIR}/prega_auth /tmp/prega_pull_secret.json
  jq -s '.[0] * .[1]' /tmp/existing_pull_secret.json /tmp/prega_pull_secret.json > /tmp/merged_pull_secret.json
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/merged_pull_secret.json
  sleep 300
  kubectl wait --for jsonpath='{.status.updatedMachineCount}'="$(oc get node --no-headers -l node-role.kubernetes.io/worker= | wc -l)" --timeout=60m mcp worker
  oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=20m

  echo "Applying the ImageDigestMirrorSet manifest"
  get_idms_manifest
  oc apply -f /tmp/idms.yaml
  sleep 300
  kubectl wait --for jsonpath='{.status.updatedMachineCount}'="$(oc get node --no-headers -l node-role.kubernetes.io/worker= | wc -l)" --timeout=60m mcp worker
  oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=20m

  echo "Creating CatalogSource for PREGA Operator Index"
  cat << EOF| oc apply -f -
  apiVersion: operators.coreos.com/v1alpha1
  kind: CatalogSource
  metadata:
    name: prega-operator-index
    namespace: openshift-marketplace
  spec:
    image: quay.io/prega/prega-operator-index:${OPERATOR_PREGA_VERSION}
    sourceType: grpc
    displayName: Openshift Pre-GA Operators
EOF

  echo "Waiting for CatalogSource to be ready"
  sleep 300
  kubectl wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY catalogsource/prega-operator-index -n openshift-marketplace --timeout=300s
  echo "CatalogSource is ready"
  oc get catalogsources.operators.coreos.com -n openshift-marketplace
  oc get packagemanifests.packages.operators.coreos.com

else
  echo "OCP_BUILD is not dev, skipping PREGA Operator Index installation"
fi
