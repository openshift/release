#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Get ACM Version x.y instead of x.y.z
ACM_VERSION=`echo "$(oc get csv -n ${ACM_NAMESPACE} -l operators.coreos.com/advanced-cluster-management.${ACM_NAMESPACE}= -o=jsonpath='{.items[].spec.version}')" | cut -d'.' -f1,2`

if [[ -z "${ACM_VERSION}" ]]; then
  echo "ACM CSV not found in namespace ${ACM_NAMESPACE}; skipping must-gather"
  exit 0
fi

# ACM must-gather
oc adm must-gather --image=registry.redhat.io/rhacm2/acm-must-gather-rhel9:v"$ACM_VERSION" --dest-dir="${ARTIFACT_DIR}"
