#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "$(date -u --rfc-3339=seconds) - Changing management state for Image Registry Operator"
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"managementState":"Removed"}}'

oc delete -f "${SHARED_DIR}/image-registry-pvc.yaml" -n openshift-image-registry

echo "$(date -u --rfc-3339=seconds) - Delete successful."