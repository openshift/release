#!/usr/bin/env bash


set -o errexit
set -o nounset
set -o pipefail

update="${update:-false}"

base=$( dirname "${BASH_SOURCE[0]}")
repo_root="$base/.."

diffFile="$repo_root/clusters/app.ci/.diff"

diff_command="git diff --no-index -- ./core-services/prow/03_deployment/ ./clusters/app.ci/prow/03_deployment/ || true"
if [[ -z "${CI:-}" ]]; then
  diff_command="docker run --rm --user=$UID -v $PWD:/repo:z --workdir /repo docker.io/openshift/origin-release:golang-1.13 $diff_command"
fi

actual_diff="$(eval $diff_command)"

if [[ "$update" = true ]]; then
  echo "$actual_diff" > $diffFile
fi

# The filename is part of the diff, so must stay stable
actual_diff_file="$repo_root/clusters/app.ci/.actual_diff"
echo "$actual_diff" > $actual_diff_file

diffDiff="$(git diff --no-index -- $actual_diff_file $diffFile || true)"

if [[ -n "$diffDiff" ]]; then
  echo "ERROR: Diff does not match expected"
  echo "ERROR: Diff from expected:"
  echo "$diffDiff"
  echo "ERROR: If this is expected, please run 'make update-app-ci and commit the result'"
  exit 1
fi
