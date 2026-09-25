#!/bin/bash
set -euo pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

oc patch configs.imageregistry.operator.openshift.io cluster \
  --type merge \
  --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'

echo "Image registry set to Managed with emptyDir storage"
