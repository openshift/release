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
export TARGET_SCC_NAME="restricted-v2-plus-netadmin"

oc create -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${TARGET_SCC_NAME}-binding
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${TARGET_SCC_NAME}
subjects:
$(oc get sa -n "${NAMESPACE}" \
  --no-headers \
  -o custom-columns=:metadata.name \
  | grep -Ev '^(default|builder|deployer)$' \
  | awk -v ns="${NAMESPACE}" '{print "- kind: ServiceAccount\n  name: "$1"\n  namespace: "ns}')
EOF


