#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
if [ -f "${SHARED_DIR}/proxy-conf.sh" ]
then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi
if [ -f "${SHARED_DIR}/image-registry-pvc.yaml" ]
then
  echo "$(date -u --rfc-3339=seconds) - Changing management state for Image Registry Operator"
  oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"managementState":"Removed"}}'
  oc delete -f "${SHARED_DIR}/image-registry-pvc.yaml"
  echo "$(date -u --rfc-3339=seconds) - Delete successful."
else
  echo "File ${SHARED_DIR}/image-registry-pvc.yaml does not exist, skipping deletion."
fi