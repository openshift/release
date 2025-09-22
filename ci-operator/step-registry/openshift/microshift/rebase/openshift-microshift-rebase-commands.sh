#!/bin/bash
set -xeuo pipefail

if [[ "$JOB_NAME" == rehearse* ]]; then
    echo "INFO: \$JOB_NAME starts with rehearse - running in DRY RUN mode"
    export DRY_RUN=y
fi

export PATH="${HOME}/.local/bin:${PATH}"
python3 -m ensurepip --upgrade
pip3 install setuptools-rust cryptography pyyaml pygithub gitpython

cp /secrets/import-secret/.dockerconfigjson ${HOME}/.pull-secret.json

#TODO temporary clone my fork.
cd /go/src/github.com/openshift/microshift/
git clone --branch USHIFT-6154 https://github.com/pacevedom/microshift.git
cd /go/src/github.com/openshift/microshift/microshift
DEST_DIR=${HOME}/.local/bin ./scripts/fetch_tools.sh yq
./scripts/auto-rebase/rebase_job_entrypoint.sh
