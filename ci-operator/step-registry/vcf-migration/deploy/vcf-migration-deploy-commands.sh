#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function log() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export HOME="${HOME:-/tmp/home}"
mkdir -p "${HOME}"

# Install kubectl if not present (src image doesn't include it)
if ! command -v kubectl &> /dev/null; then
  log "installing kubectl"
  mkdir -p "${HOME}/bin"
  curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x kubectl
  mv kubectl "${HOME}/bin/"
  export PATH="${HOME}/bin:${PATH}"
fi

if [[ -z "${VCF_MIGRATION_OPERATOR_IMAGE:-}" ]]; then
  log "VCF_MIGRATION_OPERATOR_IMAGE must be provided by ci-operator dependencies"
  exit 1
fi

log "installing CRDs"
make install

log "deploying operator image ${VCF_MIGRATION_OPERATOR_IMAGE}"
make deploy IMG="${VCF_MIGRATION_OPERATOR_IMAGE}"

log "waiting for controller deployment availability"
kubectl wait --for=condition=Available=True \
  --timeout=10m \
  deployment/vcf-migration-operator-controller-manager \
  -n openshift-vcf-migration
