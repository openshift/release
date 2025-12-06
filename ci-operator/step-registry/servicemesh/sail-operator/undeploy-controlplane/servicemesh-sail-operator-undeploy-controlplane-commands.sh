#!/bin/bash

# ==============================================================================
# Sail Operator Undeploy control plane undeploys the Istio control plane from the current
# cluster.
# ==============================================================================

set -o nounset
set -o errexit
set -o pipefail

echo "Undeploying Istio control plane from the cluster"
oc delete istios.sailoperator.io --all --all-namespaces --wait=true --ignore-not-found=true
oc delete istiocni.sailoperator.io --all --all-namespaces --wait=true --ignore-not-found=true
oc delete ztunnel.sailoperator.io --all --all-namespaces --wait=true --ignore-not-found=true
oc delete namespace istio-system --wait=true --ignore-not-found=true
oc delete namespace ztunnel --wait=true --ignore-not-found=true
oc delete namespace istio-cni --wait=true --ignore-not-found=true

# DEBUG output: list all istio components
echo "Listing Istio control plane components:"
oc get istio --all-namespaces
oc get istiocni --all-namespaces
oc get ztunnel --all-namespaces

echo "Istio control plane undeployed successfully."