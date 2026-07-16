#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/ci-functions.sh"

install -m 0600 /secrets/import-secret/.dockerconfigjson "${HOME}/.pull-secret.json"

GOARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
export GOARCH

export CRYPTO_SCAN=true
cd /go/src/github.com/openshift/microshift/
./scripts/auto-rebase/rebase_job_entrypoint.sh
