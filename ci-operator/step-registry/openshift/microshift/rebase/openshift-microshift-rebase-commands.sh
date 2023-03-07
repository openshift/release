#!/bin/bash

export DRY_RUN=y

git remote add pmtk https://github.com/pmtk/microshift.git
git fetch pmtk
git checkout -t pmtk/debug-failed-make-vendor

set +e
./scripts/auto-rebase/rebase_job_entrypoint.sh
res=$?

git status
echo -e '\n\n\n\n\n'
git diff main

exit $res
