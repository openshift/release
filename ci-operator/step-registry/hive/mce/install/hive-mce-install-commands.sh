#!/bin/bash

set -ex

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

MCE_VERSION=${MCE_VERSION:-"2.2"}
if [[ $MCE_QE_CATALOG != "true" ]]; then
  _REPO="quay.io/acm-d/mce-custom-registry"

  # Setup quay mirror container repo
  cat << EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: rhacm-repo
spec:
  repositoryDigestMirrors:
  - mirrors:
    - quay.io:443/acm-d
    source: registry.redhat.io/rhacm2
  - mirrors:
    - quay.io:443/acm-d
    source: registry.redhat.io/multicluster-engine
  - mirrors:
    - registry.redhat.io/openshift4/ose-oauth-proxy
    source: registry.access.redhat.com/openshift4/ose-oauth-proxy
EOF

  QUAY_USERNAME=$(cat /etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_username)
  QUAY_PASSWORD=$(cat /etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_pullsecret)
  oc get secret pull-secret -n openshift-config -o json | jq -r '.data.".dockerconfigjson"' | base64 -d > /tmp/global-pull-secret.json
  QUAY_AUTH=$(echo -n "${QUAY_USERNAME}:${QUAY_PASSWORD}" | base64 -w 0)
  jq --arg QUAY_AUTH "$QUAY_AUTH" '.auths += {"quay.io:443": {"auth":$QUAY_AUTH,"email":""}}' /tmp/global-pull-secret.json > /tmp/global-pull-secret.json.tmp
  mv /tmp/global-pull-secret.json.tmp /tmp/global-pull-secret.json
  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/global-pull-secret.json
  rm /tmp/global-pull-secret.json
  sleep 60
  oc wait mcp master worker --for condition=updated --timeout=20m

  VER=`oc version | grep "Client Version:"`
  echo "* oc CLI ${VER}"

  echo "Install MCE custom catalog source"
  IMG="${_REPO}:${MCE_VERSION}-latest"
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: multiclusterengine-catalog
  namespace: openshift-marketplace
spec:
  displayName: MultiCluster Engine
  publisher: Red Hat
  sourceType: grpc
  image: ${IMG}
  updateStrategy:
    registryPoll:
      interval: 10m
EOF
fi

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: multicluster-engine
EOF

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: multicluster-engine-group
  namespace: multicluster-engine
spec:
  targetNamespaces:
    - "multicluster-engine"
EOF

CATALOG=$([[ $MCE_QE_CATALOG == "true" ]] && echo -n "qe-app-registry" || echo -n "multiclusterengine-catalog")
echo "* Applying SUBSCRIPTION_CHANNEL $MCE_VERSION, SUBSCRIPTION_SOURCE $CATALOG to multiclusterengine-operator subscription"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: multicluster-engine
  namespace: multicluster-engine
spec:
  channel: stable-${MCE_VERSION}
  installPlanApproval: Automatic
  name: multicluster-engine
  source: ${CATALOG}
  sourceNamespace: openshift-marketplace
EOF

CSVName=""
for ((i=1; i<=60; i++)); do
  output=$(oc get sub multicluster-engine -n multicluster-engine -o jsonpath='{.status.currentCSV}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    sleep 2
    continue
  fi
  CSVName=$(oc get sub -n multicluster-engine multicluster-engine -o jsonpath='{.status.currentCSV}')
  if [ "$CSVName" != "" ]; then
    break
  fi
  sleep 10
done

_apiReady=0
echo "* Using CSV: ${CSVName}"
for ((i=1; i<=20; i++)); do
  sleep 30
  output=$(oc get csv -n multicluster-engine $CSVName -o jsonpath='{.status.phase}' >> /dev/null && echo "exists" || echo "not found")
  if [ "$output" != "exists" ]; then
    continue
  fi
  phase=$(oc get csv -n multicluster-engine $CSVName -o jsonpath='{.status.phase}')
  if [ "$phase" == "Succeeded" ]; then
    _apiReady=1
    break
  fi
  echo "Waiting for CSV to be ready"
done

if [ $_apiReady -eq 0 ]; then
  echo "multiclusterengine subscription could not install in the allotted time."
  exit 1
fi
echo "multiclusterengine installed successfully"

oc apply -f - <<EOF
apiVersion: multicluster.openshift.io/v1
kind: MultiClusterEngine
metadata:
  name: multiclusterengine-sample
spec: {}
EOF
sleep 5

# Check if the hive operator is ready
oc wait --timeout=20m --for=condition=Available MultiClusterEngine/multiclusterengine-sample
oc wait --timeout=10m --for=condition=Ready pod -n multicluster-engine -l control-plane=hive-operator
oc wait --timeout=10m --for=condition=Ready pod -n hive -l control-plane=clustersync
oc wait --timeout=10m --for=condition=Ready pod -n hive -l control-plane=controller-manager
oc wait --timeout=10m --for=condition=Ready pod -n hive -l control-plane=machinepool
oc wait --timeout=10m --for=condition=Ready pod -n hive -l app=hiveadmission
oc wait --timeout=10m --for=condition=Ready hiveconfig hive