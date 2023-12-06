#!/bin/bash

set -ex

_REPO="quay.io/acm-d/mce-custom-registry"
MCE_VERSION=${MCE_VERSION:-"2.2"}

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

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: multicluster-engine
EOF

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

echo "* Applying SUBSCRIPTION_CHANNEL $MCE_VERSION to multiclusterengine-operator subscription"
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
  source: multiclusterengine-catalog
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

# Enable Hypershift Preview
oc apply -f - <<EOF
apiVersion: multicluster.openshift.io/v1
kind: MultiClusterEngine
metadata:
  name: multiclusterengine-sample
spec: {}
EOF
sleep 5

oc patch mce multiclusterengine-sample --type=merge -p '{"spec":{"overrides":{"components":[{"name":"hypershift-preview","enabled": true}]}}}'
echo "wait for mce to Available"
oc wait --timeout=20m --for=condition=Available MultiClusterEngine/multiclusterengine-sample

oc apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  labels:
    local-cluster: "true"
  name: local-cluster
spec:
  hubAcceptsClient: true
  leaseDurationSeconds: 60
EOF
oc wait --timeout=5m --for=condition=HubAcceptedManagedCluster -n local-cluster ManagedCluster/local-cluster
oc wait --timeout=5m --for=condition=ManagedClusterImportSucceeded -n local-cluster ManagedCluster/local-cluster
oc wait --timeout=5m --for=condition=ManagedClusterConditionAvailable -n local-cluster ManagedCluster/local-cluster
oc wait --timeout=5m --for=condition=ManagedClusterJoined -n local-cluster ManagedCluster/local-cluster
echo "MCE local-cluster is ready!"

oc apply -f - <<EOF
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: hypershift-addon
  namespace: local-cluster
spec:
  installNamespace: open-cluster-management-agent-addon
EOF

# wait for hypershift operator to come online
_hypershiftReady=0
set +e
for ((i=1; i<=20; i++)); do
  oc get pods -n hypershift | grep "operator.*Running"
  if [ $? -eq 0 ]; then
    _hypershiftReady=1
    break
  fi
  echo "Waiting on hypershift operator to install"
  sleep 30
done
set -e

if [ $_hypershiftReady -eq 0 ]; then
  echo "hypershift operator did not come online in expected time"
  exit 1
fi
echo "hypershift is online!"

echo "Configuring the hosting service cluster"
oc create secret generic hypershift-operator-oidc-provider-s3-credentials --from-file=credentials=/etc/hypershift-pool-aws-credentials/credentials --from-literal=bucket=hypershift-ci-oidc --from-literal=region=us-east-1 -n local-cluster
oc label secret hypershift-operator-oidc-provider-s3-credentials -n local-cluster cluster.open-cluster-management.io/backup=true
# wait for Configuring the hosting service cluster
_configReady=0
set +e
for ((i=1; i<=10; i++)); do
  oc get configmap -n kube-public oidc-storage-provider-s3-config
  if [ $? -eq 0 ]; then
    _configReady=1
    break
  fi
  echo "Waiting on Configuring the hosting service cluster"
  sleep 30
done
set -e
if [ $_configReady -eq 0 ]; then
  echo "Configuring error"
  exit 1
fi
echo "Configuring the hosting service cluster Succeeded!"

# export icsp for hypershift hostedcluster if needed
oc get imagecontentsourcepolicy -oyaml > /tmp/mgmt_iscp.yaml && yq-go r /tmp/mgmt_iscp.yaml 'items[*].spec.repositoryDigestMirrors' -  | sed  '/---*/d' > ${SHARED_DIR}/mgmt_iscp.yaml

echo "wait for addon to Available"
oc wait --timeout=5m --for=condition=Available -n local-cluster ManagedClusterAddOn/hypershift-addon
oc wait --timeout=5m --for=condition=Degraded=False -n local-cluster ManagedClusterAddOn/hypershift-addon