#!/bin/bash

set -x

export BASE_BRANCH=release-4.12
git remote add pmtk https://github.com/pmtk/microshift.git
git fetch pmtk
git checkout -t pmtk/release-4.12-fix-rebase

./scripts/auto-rebase/rebase_job_entrypoint.sh

git status

git diff
