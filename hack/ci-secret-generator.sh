#!/usr/bin/env bash

set -euo pipefail

export VAULT_ADDR=https://vault.ci.openshift.org
if ! vault kv get kv/dptp/build_farm >/dev/null; then
  echo "Must be logged into vault, run 'vault login -method=oidc'"
  exit 1
fi

VAULT_TOKEN="${VAULT_TOKEN:-$(cat ~/.vault-token)}"

BASE_DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
cluster="${cluster:-}"
echo $BASE_DIR

$CONTAINER_ENGINE pull registry.ci.openshift.org/ci/ci-secret-generator:latest
$CONTAINER_ENGINE run --rm \
  -v "${BASE_DIR}/core-services/ci-secret-bootstrap/_config.yaml:/bootstrap/_config.yaml:z" \
  -v "${BASE_DIR}/core-services/ci-secret-generator/_config.yaml:/generator/_config.yaml:z" \
  -v "$kubeconfig_path:/_kubeconfig:z" \
  -e VAULT_TOKEN="$VAULT_TOKEN" \
  -e KUBECONFIG=/_kubeconfig \
  registry.ci.openshift.org/ci/ci-secret-generator:latest \
    --vault-addr=${VAULT_ADDR} \
    --config=/generator/_config.yaml \
    --bootstrap-config=/bootstrap/_config.yaml \
    --vault-prefix=kv/dptp \
    --dry-run=${dry_run}
