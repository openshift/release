#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This step wants to always talk to the build farm (via service account credentials) but ci-operator
# gives steps KUBECONFIG pointing to cluster under test under some circumstances, which is never
# the correct cluster to interact with for this step.
unset KUBECONFIG

# Allow any service account in the test namespace the use of net_admin / net_raw. The target
# SCC adds these capabilities to pods by these service accounts by default. So any test pod
# running after this one should receive these caps.
oc adm policy add-scc-to-group -n "${NAMESPACE}" restricted-v2-plus-netadmin "system:serviceaccount:${NAMESPACE}"
