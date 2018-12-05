#!/bin/bash

# This script ensures that all component config files are accompanied by OWNERS file

set -o errexit
set -o nounset
set -o pipefail

NO_OWNERS="$(mktemp)"
trap 'rm -f $NO_OWNERS' EXIT

REPOROOT="$( dirname "${BASH_SOURCE[0]}" )/.."

pushd "$REPOROOT" > /dev/null

find ci-operator/config -mindepth 2  -type d '!' -exec test -e "{}/OWNERS" ';' -print > "$NO_OWNERS"
find ci-operator/jobs -mindepth 2  -type d '!' -exec test -e "{}/OWNERS" ';' -print >> "$NO_OWNERS"

popd > /dev/null

if test -s "$NO_OWNERS"; then
  cat << EOF
[ERROR] This check enforces that component configuration files are accompanied by OWNERS
[ERROR] files so that the appropriate team is able to self-service further configuration
[ERROR] change pull requests.

[ERROR] Run the following script to fetch OWNERS files from the component repositories:

[ERROR] $ ci-operator/populate-owners.sh

[ERROR] Please note that the script populates *all* ci-operator subdirectories, and it
[ERROR] takes a long time to execute (tens of minutes). If the target repository does not
[ERROR] contain an OWNERS file, it will need to be created manually.

[ERROR] The following component config directories do not have OWNERS files:
EOF
  cat "$NO_OWNERS"
fi
