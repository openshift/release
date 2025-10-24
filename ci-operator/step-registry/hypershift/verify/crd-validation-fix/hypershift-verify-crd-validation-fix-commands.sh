#!/bin/bash

set -ex

echo "Starting CRD validation fix verification for hypershift"

# Wait for hypershift operator to be ready
echo "Waiting for hypershift operator to be ready..."
oc wait deployment operator -n hypershift --for condition=Available=True --timeout=10m

# Check if hypershift operator is running
oc get pods -n hypershift

# Get the hypershift operator version
echo "Hypershift operator version:"
oc get deployment operator -n hypershift -o jsonpath='{.spec.template.spec.containers[*].image}'
echo

# Check for the specific CRD validation error
echo "Checking for CRD validation errors..."

# Get the hostedclusters CRD
echo "Retrieving hostedclusters CRD..."
oc get crd hostedclusters.hypershift.openshift.io -o yaml > /tmp/hostedclusters-crd.yaml

# Check if the CRD contains the problematic validation rule
echo "Checking for problematic validation rule with '.?' syntax..."
if grep -q "self\.\?operatorConfiguration\.clusterNetworkOperator\.ovnKubernetesConfig\.hasValue()" /tmp/hostedclusters-crd.yaml; then
    echo "ERROR: Found problematic validation rule with '.?' syntax in hostedclusters CRD"
    echo "This indicates the CRD validation bug still exists"
    
    # Extract the validation rule for analysis
    echo "Problematic validation rule:"
    grep -A 5 -B 5 "self\.\?operatorConfiguration\.clusterNetworkOperator\.ovnKubernetesConfig\.hasValue()" /tmp/hostedclusters-crd.yaml || true
    
    # Try to apply a test hostedcluster to trigger the validation error
    echo "Attempting to create a test hostedcluster to trigger validation error..."
    
    cat << EOF > /tmp/test-hostedcluster.yaml
apiVersion: hypershift.openshift.io/v1beta1
kind: HostedCluster
metadata:
  name: test-crd-validation
  namespace: local-cluster
spec:
  networking:
    networkType: OpenShiftSDN
  platform:
    type: AWS
    aws:
      region: us-east-1
  release:
    image: registry.ci.openshift.org/ocp/release:4.21.0-0.nightly-2025-10-23-225733
  pullSecret:
    name: pull-secret
  sshKey:
    name: ssh-key
EOF

    # This should fail with the CRD validation error
    if oc apply -f /tmp/test-hostedcluster.yaml 2>&1 | grep -q "unsupported syntax"; then
        echo "CONFIRMED: CRD validation error with unsupported syntax '.?' still exists"
        echo "The bug has NOT been fixed in the nightly build"
        exit 1
    else
        echo "SUCCESS: No CRD validation error detected - the bug may be fixed"
    fi
    
    # Clean up test resource
    oc delete hostedcluster test-crd-validation -n local-cluster --ignore-not-found=true
    
else
    echo "SUCCESS: No problematic validation rule found with '.?' syntax"
    echo "The CRD validation bug appears to be fixed"
fi

# Display the full CRD for analysis
echo "Full hostedclusters CRD:"
cat /tmp/hostedclusters-crd.yaml

# Check for any other validation rules that might cause issues
echo "Checking for other potential validation rule issues..."
if grep -q "x-kubernetes-validations" /tmp/hostedclusters-crd.yaml; then
    echo "Found x-kubernetes-validations in CRD:"
    grep -A 10 -B 2 "x-kubernetes-validations" /tmp/hostedclusters-crd.yaml || true
fi

echo "CRD validation fix verification completed"