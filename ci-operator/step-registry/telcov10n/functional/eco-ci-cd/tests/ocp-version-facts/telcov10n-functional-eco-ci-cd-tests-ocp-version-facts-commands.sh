#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

cd /eco-ci-cd

# run_tests.py locates the repo root via `git rev-parse --show-toplevel` to
# resolve ansible.cfg's relative roles_path/collections_path. .containerignore
# excludes .git from this image's build context, so give it a minimal repo.
[[ -d .git ]] || git init -q

./playbooks/roles/ocp_version_facts/tests/run_tests.py
