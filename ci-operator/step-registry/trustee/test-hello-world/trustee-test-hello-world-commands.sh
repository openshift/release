#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "========================================"
echo "Hello World Test"
echo "========================================"

echo "Cluster info:"
oc version

echo ""
echo "Checking Trustee operator installation:"
oc get pods -n trustee-operator-system

echo ""
echo "Checking TrusteeConfig:"
oc get trusteeconfig -n trustee-operator-system

echo ""
echo "========================================"
echo "Hello World Test PASSED!"
echo "========================================"
