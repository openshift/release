#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This step wants to always talk to the build farm (via service account credentials) but ci-operator
# gives steps KUBECONFIG pointing to cluster under test under some circumstances, which is never
# the correct cluster to interact with for this step.
unset KUBECONFIG

# We want the test cluster to be able to access these images on the build farm
echo "Add policies to allow the test cluster access to images on the build farm..."
oc adm policy add-role-to-group system:image-puller system:authenticated --namespace "${NAMESPACE}"
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
