#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release


oc config view
oc projects

if [ ${OCP_BUILD} == "dev" ]; then
  echo "Patching OperatorHub to disable all default sources"
  oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

  PREGA_AUTH="$(cat /secret/prega_auth)"
  oc get secret pull-secret -n openshift-config -o json | jq -r '.data[".dockerconfigjson"]' | base64 -d > /tmp/existing_pull_secret.json
  echo ${PREGA_AUTH} > /tmp/prega_pull_secret.json
  jq -s '.[0] * .[1]' /tmp/existing_pull_secret.json /tmp/prega_pull_secret.json > /tmp/merged_pull_secret.json
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/merged_pull_secret.json
  sleep 300
  kubectl wait --for jsonpath='{.status.updatedMachineCount}'="$(oc get node --no-headers -l node-role.kubernetes.io/worker=true | wc -l)" --timeout=60m mcp worker
  oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=20m

  OCP_VERSION=$(oc get clusterversion --no-headers | grep -o '[4].[0-9][0-9]' | head -1 | awk '{print "v"$0}')
  OPERATOR_PREGA_VERSION=$(curl -s 'https://quay.io/api/v1/repository/prega/prega-operator-index/tag/?limit=100&page=1' | jq --arg version "$OCP_VERSION" -r '.tags[].name | select(startswith($version))' | sort -V | tail -1)
  echo "Installing PREGA Operator ${OPERATOR_PREGA_VERSION} for OCP ${OCP_VERSION}"
  curl -o /tmp/idms.yaml http://${PREGA_BUILD_SERVER_IP}/${OPERATOR_PREGA_VERSION}/imageDigestMirrorSet.yaml
  oc apply -f /tmp/idms.yaml
  sleep 300
  kubectl wait --for jsonpath='{.status.updatedMachineCount}'="$(oc get node --no-headers -l node-role.kubernetes.io/worker=true | wc -l)" --timeout=60m mcp worker
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
  oc get packagemanifests.packages.operators.coreos.com

else
  echo "OCP_BUILD is not dev, skipping PREGA Operator Index installation"
fi


