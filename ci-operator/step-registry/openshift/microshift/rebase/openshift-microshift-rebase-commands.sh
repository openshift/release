#!/bin/bash
set -xeuo pipefail

export PATH="${HOME}/.local/bin:${PATH}"
python3 -m ensurepip --upgrade
pip3 install setuptools-rust cryptography pyyaml pygithub gitpython

cp /secrets/import-secret/.dockerconfigjson ${HOME}/.pull-secret.json

cd /go/src/github.com/openshift/microshift/
sed -i 's,DRY_RUN=y,DRY_RUN=,g' ./scripts/auto-rebase/rebase_job_entrypoint.sh
DEST_DIR=${HOME}/.local/bin ./scripts/fetch_tools.sh yq
./scripts/auto-rebase/rebase_job_entrypoint.sh
