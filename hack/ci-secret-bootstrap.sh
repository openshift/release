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

$CONTAINER_ENGINE pull registry.ci.openshift.org/ci/ci-secret-bootstrap:latest
$CONTAINER_ENGINE run --rm -v "${BASE_DIR}/core-services/ci-secret-bootstrap/_config.yaml:/_config.yaml:z" \
  -v "$kubeconfig_path:/_kubeconfig:z" \
  -e VAULT_TOKEN="$VAULT_TOKEN" \
  registry.ci.openshift.org/ci/ci-secret-bootstrap:latest \
  --vault-addr=${VAULT_ADDR} \
  --vault-prefix=kv \
  --config=/_config.yaml \
  --kubeconfig=/_kubeconfig \
  --dry-run=${dry_run} \
  --force=${force} \
  --cluster=${cluster} \
  --as=system:admin
