#!/bin/bash

export DRY_RUN=y

git remote add pmtk https://github.com/pmtk/microshift.git
git fetch pmtk
git switch --track pmtk/rebase/recipe

./scripts/auto-rebase/rebase_job_entrypoint.sh

git diff rebase/recipe
