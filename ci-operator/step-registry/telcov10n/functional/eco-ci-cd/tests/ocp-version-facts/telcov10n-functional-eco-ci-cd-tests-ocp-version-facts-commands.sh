#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

cd /eco-ci-cd

# run_tests.py locates the repo root via `git rev-parse --show-toplevel` to
# resolve ansible.cfg's relative roles_path/collections_path. /eco-ci-cd is
# baked into the image read-only for this container's arbitrary UID (and
# .containerignore excludes .git from the build context anyway), so point
# git at a git-dir in a writable scratch location instead of initializing
# one inside /eco-ci-cd.
export GIT_DIR="$(mktemp -d)/.git"
export GIT_WORK_TREE=/eco-ci-cd
git init -q

./playbooks/roles/ocp_version_facts/tests/run_tests.py
