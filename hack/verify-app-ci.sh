#!/usr/bin/env bash


set -o errexit
set -o nounset
set -o pipefail

update="${update:-false}"

base=$( dirname "${BASH_SOURCE[0]}")
repo_root="$base/.."

diffFile="$repo_root/clusters/app.ci/.diff"

# There two are currently identical, so just copy over rather than
# changing the diff.
if [[ "$update" = true ]]; then
  cp -r $repo_root/core-services/prow/02_config/* $repo_root/clusters/app.ci/prow/02_config/
fi

actual_diff="$(diff \
  --recursive \
  -u \
  --new-file \
  --label=o \
  --label=m \
  $repo_root/core-services/prow/ \
  $repo_root/clusters/app.ci/prow/ || true)"

if [[ "$update" = true ]]; then
  echo "$actual_diff" > $diffFile
fi

expected_diff="$(cat $repo_root/clusters/app.ci/.diff)"

diffDiff="$(diff <(echo "$actual_diff") <(echo "$expected_diff") || true)"

if [[ -n "$diffDiff" ]]; then
  echo "ERROR: Diff does not match expected"
  echo "ERROR: Diff from expected:"
  echo "$diffDiff"
  echo "ERROR: If this is expected, please run 'make update-app-ci and commit the result'"
  exit 1
fi
