#!/bin/bash
set -o errexit

set -o nounset
set -o pipefail
set -x

helm install krkn-operator oci://quay.io/krkn-chaos/charts/krkn-operator \
  --version $KRKN_OPERATOR_VERSION \
  --namespace $TARGET_NAMESPACE \
  --create-namespace \
  --set acm.enabled=true