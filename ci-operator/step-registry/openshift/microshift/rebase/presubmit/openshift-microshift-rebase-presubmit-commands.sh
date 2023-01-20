#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

printenv

command -v git &> /dev/null || dnf install -y git

git remote add pmtk https://github.com/pmtk/microshift.git
git switch -t pmtk/rebase-presubmit

./scripts/auto-rebase/presubmit.py
