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
echo "BASE_DIR=${BASE_DIR}"
dry_run="${dry_run:-true}"

set -x

CONTAINER_ENGINE=${CONTAINER_ENGINE:-podman}
$CONTAINER_ENGINE login -u=$(oc --context app.ci whoami) -p=$(oc --context app.ci whoami -t) quay-proxy.ci.openshift.org --authfile /tmp/t.c
$CONTAINER_ENGINE pull quay-proxy.ci.openshift.org/openshift/ci:ci_ci-secret-generator_latest --authfile /tmp/t.c
$CONTAINER_ENGINE run --rm \
  -v "${BASE_DIR}/core-services/ci-secret-bootstrap/_config.yaml:/bootstrap/_config.yaml:z" \
  -v "${BASE_DIR}/core-services/ci-secret-generator/_config.yaml:/generator/_config.yaml:z" \
  -v "${BUILD_FARM_CREDENTIALS_FOLDER}:/tmp/build-farm-credentials:z" \
  -e VAULT_TOKEN="$VAULT_TOKEN" \
  quay-proxy.ci.openshift.org/openshift/ci:ci_ci-secret-generator_latest \
    --vault-addr=${VAULT_ADDR} \
    --config=/generator/_config.yaml \
    --bootstrap-config=/bootstrap/_config.yaml \
    --vault-prefix=kv/dptp \
    --dry-run=${dry_run}
