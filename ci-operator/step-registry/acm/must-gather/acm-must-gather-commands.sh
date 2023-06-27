#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# ACM must-gather
oc adm must-gather --image=registry.redhat.io/rhacm2/acm-must-gather-rhel8:v"$(oc get csv -n ${ACM_NAMESPACE} -l operators.coreos.com/advanced-cluster-management.${ACM_NAMESPACE}= -o=jsonpath='{.items[].spec.version}')" --dest-dir="${ARTIFACT_DIR}"
# MCE must-gather
oc adm must-gather --image=registry.redhat.io/multicluster-engine/must-gather-rhel8:v"$(oc get csv  -n multicluster-engine -l operators.coreos.com/multicluster-engine.multicluster-engine= -o=jsonpath='{.items[].spec.version}')" --dest-dir="${ARTIFACT_DIR}"
