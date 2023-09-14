#!/bin/bash

# if [[ "$JOB_NAME" == rehearse* ]]; then
#     echo "INFO: \$JOB_NAME starts with rehearse - running in DRY RUN mode"
#     export DRY_RUN=y
# fi

sed -i '11,15d' ./scripts/auto-rebase/rebase_job_entrypoint.sh

./scripts/auto-rebase/rebase_job_entrypoint.sh
