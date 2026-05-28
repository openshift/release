#!/bin/bash

set -euo pipefail

export KUBECTL="oc"
ls -al
cd quay-rapidast

cp "${KUBECONFIG}" ./kubeconfig
cp /var/run/quay-qe-dast-gcs-secret/gcs-key.json ./gcs-key.json

# Disable tracing due to password handling
[[ $- == *x* ]] && _tracing=true || _tracing=false
set +x
cat > quay-credentials.yaml <<CREDS
username: $(cat /var/run/quay-qe-quay-secret/username)
password: $(cat /var/run/quay-qe-quay-secret/password)
CREDS
$_tracing && set -x

export KUBECONFIG="./kubeconfig"
export GCS_CREDS="./gcs-key.json"
export QUAY_NAMESPACE="${QUAY_NAMESPACE:-quay-enterprise}"
export RAPIDAST_NS="${RAPIDAST_NS:-rapidast}"
export RAPIDAST_IMAGE="${RAPIDAST_IMAGE:-quay.io/redhatproductsecurity/rapidast:2.13.0}"

bash generate-quay-config ./quay-credentials.yaml

cp *-scan.yaml "${ARTIFACT_DIR}/" 2>/dev/null || true
cp quay-openapi.json "${ARTIFACT_DIR}/" 2>/dev/null || true

bash run-quay-scan all

for job in rapidast-quay rapidast-clair rapidast-oobtkube rapidast-trivy; do
  oc --kubeconfig="${KUBECONFIG}" logs "job/${job}" -n "${RAPIDAST_NS}" > "${ARTIFACT_DIR}/${job}.log" 2>/dev/null || true
done
