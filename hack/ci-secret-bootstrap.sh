#!/usr/bin/env bash

set -euo pipefail

export VAULT_ADDR=https://vault.ci.openshift.org
if ! vault kv get kv/dptp/build_farm >/dev/null; then
  echo "Must be logged into vault, run 'vault login -method=oidc'"
  exit 1
fi

VAULT_TOKEN="${VAULT_TOKEN:-$(cat ~/.vault-token)}"
BUILD_FARM_CREDENTIALS_FOLDER="${BUILD_FARM_CREDENTIALS_FOLDER:-/tmp/build-farm-credentials}"
echo "BUILD_FARM_CREDENTIALS_FOLDER=${BUILD_FARM_CREDENTIALS_FOLDER}"

BASE_DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
cluster="${cluster:-}"
echo $BASE_DIR
dry_run="${dry_run:-true}"
force="${force:-false}"

if [[ -n "${secret_names:-}" ]]; then
  arg="--secret-names=${secret_names}"
fi


set -x

$CONTAINER_ENGINE pull registry.ci.openshift.org/ci/ci-secret-bootstrap:latest
$CONTAINER_ENGINE run --rm -v "${BASE_DIR}/core-services/ci-secret-bootstrap/_config.yaml:/_config.yaml:z" \
  -v "${BUILD_FARM_CREDENTIALS_FOLDER}:/tmp/build-farm-credentials:z" \
  -e VAULT_TOKEN="$VAULT_TOKEN" \
  registry.ci.openshift.org/ci/ci-secret-bootstrap:latest \
  --vault-addr=${VAULT_ADDR} \
  --vault-prefix=kv \
  --config=/_config.yaml \
  --kubeconfig-dir=/tmp/build-farm-credentials \
  --kubeconfig-suffix=config
  --dry-run=${dry_run} \
  --force=${force} \
  --cluster=${cluster} \
  ${arg:-} \
  --as=system:admin
