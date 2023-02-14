#!/bin/bash

printenv

git remote add pmtk https://github.com/pmtk/microshift.git
git fetch pmtk
git switch --track pmtk/rebase/recipe-simple-presubmit

./scripts/auto-rebase/presubmit.py
