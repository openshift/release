#!/bin/bash
set -euo pipefail

oc patch configs.imageregistry.operator.openshift.io cluster \
  --type merge \
  --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'

echo "Image registry set to Managed with emptyDir storage"
