#!/usr/bin/env bash


set -o errexit
set -o nounset
set -o pipefail

update="${update:-false}"

base=$( dirname "${BASH_SOURCE[0]}")
repo_root="$base/.."

diffFile="$repo_root/core-services-v2/.diff"

actual_diff="$(diff \
  --recursive \
  -u \
  --new-file \
  --label=o \
  --label=m \
  $repo_root/core-services/prow/ \
  $repo_root/core-services-v2/prow/ || true)"

# Remove timestamp, this will stop working in the year 10000
#actual_diff="$(echo $actual_diff| sed -E 's/\s*[0-9]{4}-[0-9]{2}-[0-9]{2}.+?(?=@@)//g')"

if [[ "$update" = true ]]; then
  echo "$actual_diff" > $diffFile
fi

expected_diff="$(cat $repo_root/core-services-v2/.diff)"

diffDiff="$(diff <(echo "$actual_diff") <(echo "$expected_diff") || true)"

if [[ -n "$diffDiff" ]]; then
  echo "ERROR: Diff does not match expected"
  echo "ERROR: Diff from expected:"
  echo "$diffDiff"
  echo "ERROR: If this is expected, please run 'make update-core-services-v2 and commit the result'"
  exit 1
fi
