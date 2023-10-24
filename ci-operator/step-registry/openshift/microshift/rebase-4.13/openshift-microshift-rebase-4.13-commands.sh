#!/bin/bash
set -xeuo pipefail

if [[ "$JOB_NAME" == rehearse* ]]; then
    echo "INFO: \$JOB_NAME starts with rehearse - running in DRY RUN mode"
    export DRY_RUN=y
fi

./scripts/auto-rebase/rebase_job_entrypoint.sh
