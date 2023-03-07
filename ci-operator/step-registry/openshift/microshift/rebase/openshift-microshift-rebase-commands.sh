#!/bin/bash

export DRY_RUN=y
git status
git branch

git remote add pmtk https://github.com/pmtk/microshift.git
git fetch pmtk
git switch --track pmtk/rebase/lvms-ec

git branch

./scripts/auto-rebase/rebase_job_entrypoint.sh

git diff rebase/lvms-ec
