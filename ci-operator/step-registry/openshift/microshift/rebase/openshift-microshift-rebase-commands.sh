#!/bin/bash

if [[ "$JOB_NAME" == rehearse* ]]; then
    echo "INFO: \$JOB_NAME starts with rehearse - running in DRY RUN mode"
    export DRY_RUN=y
fi

git remote add pmtk https://github.com/pmtk/microshift.git
git fetch pmtk
git switch -c rebase-python3 pmtk/rebase-python3

./scripts/auto-rebase/rebase_job_entrypoint.sh
