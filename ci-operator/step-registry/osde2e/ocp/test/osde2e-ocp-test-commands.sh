#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

mkdir -p "${HOME}"

REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
export REGION
ZONE="$(oc get -o jsonpath='{.items[0].metadata.labels.failure-domain\.beta\.kubernetes\.io/zone}' nodes)"
export ZONE
export TEST_PROVIDER="{\"type\":\"aws\",\"region\":\"${REGION}\",\"zone\":\"${ZONE}\",\"multizone\":true,\"multimaster\":true}"

openshift-tests run "${OCP_SUITE}" \
  --provider "${TEST_PROVIDER}" \
  -o "${ARTIFACT_DIR}/e2e.log" \
  --junit-dir "${ARTIFACT_DIR}/junit" &
