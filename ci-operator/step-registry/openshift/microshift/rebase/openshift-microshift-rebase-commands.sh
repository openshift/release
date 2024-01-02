#!/bin/bash
set -xeuo pipefail

if [[ "$JOB_NAME" == rehearse* ]]; then
    echo "INFO: \$JOB_NAME starts with rehearse - running in DRY RUN mode"
    export DRY_RUN=y
fi

export PATH="${HOME}/.local/bin:${PATH}"
python3 -m ensurepip --upgrade
pip3 install setuptools-rust cryptography pyyaml pygithub gitpython

cd /go/src/github.com/openshift/microshift/
DEST_DIR=${HOME}/.local/bin ./scripts/fetch_tools.sh yq
./scripts/auto-rebase/rebase_job_entrypoint.sh
