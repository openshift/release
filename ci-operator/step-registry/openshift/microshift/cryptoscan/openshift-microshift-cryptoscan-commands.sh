#!/bin/bash
set -euo pipefail

cp /secrets/import-secret/.dockerconfigjson ${HOME}/.pull-secret.json

export CRYPTO_SCAN=true
cd /go/src/github.com/openshift/microshift/
./scripts/auto-rebase/rebase_job_entrypoint.sh
