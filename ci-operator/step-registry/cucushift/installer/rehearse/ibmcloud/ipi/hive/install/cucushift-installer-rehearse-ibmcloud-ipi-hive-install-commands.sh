#!/bin/bash

set -euo pipefail
set -x

echo "Installing Hive from pipeline image: ${HIVE_IMAGE}"

# Deploy Hive using the image built from the current PR
export HIVE_IMAGE_OVERRIDE="${HIVE_IMAGE}"

# Deploy Hive to the cluster
make deploy

# Wait for Hive CRDs to be established
echo "Waiting for Hive CRDs to be established..."
oc wait --for=condition=Established crd/hiveconfigs.hive.openshift.io --timeout=5m || {
  echo "Failed to establish HiveConfig CRD"
  exit 1
}
oc wait --for=condition=Established crd/clusterdeployments.hive.openshift.io --timeout=5m || {
  echo "Failed to establish ClusterDeployment CRD"
  exit 1
}

# Wait for Hive operator to be ready
echo "Waiting for Hive operator pods to be ready..."
oc wait --timeout=10m --for=condition=Ready pod -n hive -l control-plane=hive-operator || {
  echo "Hive operator pod not ready"
  oc get pods -n hive
  exit 1
}

# Wait for HiveConfig to be ready
echo "Waiting for HiveConfig to be ready..."
oc wait --timeout=10m --for=condition=Ready hiveconfig hive || {
  echo "HiveConfig not ready"
  oc get hiveconfig hive -o yaml
  exit 1
}

# Wait for all Hive controller pods to be ready
echo "Waiting for Hive controller pods..."
oc wait --timeout=10m --for=condition=Ready pod -n hive -l control-plane=controller-manager || {
  echo "Hive controller-manager pod not ready"
  oc get pods -n hive
  exit 1
}

oc wait --timeout=10m --for=condition=Ready pod -n hive -l control-plane=clustersync || {
  echo "Hive clustersync pod not ready"
  oc get pods -n hive
  exit 1
}

echo "Hive installation completed successfully"
oc get pods -n hive
