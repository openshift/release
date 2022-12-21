#!/bin/bash

set -ex

DOWNSTREAM=${DOWNSTREAM:-"false"}
_REPO="quay.io/stolostron/cmb-custom-registry"
if [ "$DOWNSTREAM" == "true" ]; then
    _REPO="quay.io/acm-d/mce-custom-registry"
fi
MCE_VERSION=${MCE_VERSION:-"2.2"}

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
for ((i=1; i<=10; i++)); do
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
for ((i=1; i<=10; i++)); do
  sleep 10
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

if [ $_apiReady -eq 1 ]; then
  # Enable Hypershift Preview
  oc apply -f - <<EOF
apiVersion: multicluster.openshift.io/v1
kind: MultiClusterEngine
metadata:
  name: multiclusterengine-sample
spec: {}
EOF
  if [ "$DOWNSTREAM" == "true" ]; then
    oc annotate mce multiclusterengine-sample imageRepository=quay.io:443/acm-d
  fi
  echo "multiclusterengine installed successfully"
  sleep 5
else
  echo "multiclusterengine subscription could not install in the allotted time."
  exit 1
fi

oc patch mce multiclusterengine-sample --type=merge -p '{"spec":{"overrides":{"components":[{"name":"hypershift-preview","enabled": true}]}}}'

# It takes some time for this api to become available.
# So we try multiple times until it succeeds
# wait for hypershift operator to come online
_localClusterReady=0
set +e
for ((i=1; i<=10; i++)); do
  oc get managedcluster local-cluster -o 'jsonpath={.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' >> /dev/null
  if [ $? -eq 0 ]; then
    _localClusterReady=1
    break
  fi
  echo "Waiting for MCE local-cluster to be ready..."
  sleep 15
done
set -e

if [ $_localClusterReady -eq 0 ]; then
  echo "FATAL: MCE local-cluster failed to be ready. Check operator on hub for more details."
  exit 1
fi
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
for ((i=1; i<=10; i++)); do
  oc get pods -n hypershift | grep "operator.*Running"
  if [ $? -eq 0 ]; then
    _hypershiftReady=1
    break
  fi
  echo "Waiting on hypershift operator to install"
  sleep 15
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