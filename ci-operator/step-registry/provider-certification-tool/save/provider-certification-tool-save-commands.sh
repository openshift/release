#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

RESULTS_URL="gs://origin-ci-test/logs/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/provider-certification-tool-run/artifacts/certification-results/"
TOKEN=$(cat /var/run/vault/opct/github-token)
VERSION=$(oc get clusterversion version -o=jsonpath='{.status.desired.version}')

curl -X POST \
-H "Accept: Accept: application/vnd.github+json" \
-H "Authorization: Bearer ${TOKEN}" \
https://api.github.com/repos/redhat-openshift-ecosystem/provider-certification-tool/actions/workflows/push-image.yaml/dispatches \
-d '{"ref":"push-results","inputs":{"results_url":"'"${RESULTS_URL}"'","cluster_version":"'"${VERSION}"'","platformType":"'"${CLUSTER_TYPE}"'"}'
