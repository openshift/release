#!/usr/bin/env bash
set -euxo pipefail

source "${SHARED_DIR}/env"
echo "Using Operator Image: ${OPERATOR_IMAGE}"
echo "Using Bundle Image: ${BUNDLE_IMAGE}"

CSV=$(oc get csv -n openshift-kueue-operator -o jsonpath='{.items[0].metadata.name}')
oc patch csv -n openshift-kueue-operator $CSV --type=json -p="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image\", \"value\": \"$OPERATOR_IMAGE\"}]"