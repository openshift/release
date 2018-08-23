#!/bin/bash

# This script ensures that the Prow configuration checked into git is up-to-date
# with the generator. If it is not, re-generate the configuration to update it.

set -o errexit
set -o nounset
set -o pipefail

workdir="$( mktemp -d )"
trap 'rm -rf "${workdir}"' EXIT

ci_operator_dir="$( dirname "${BASH_SOURCE[0]}" )/../ci-operator"

cp -r "${ci_operator_dir}" "${workdir}"

"$( dirname "${BASH_SOURCE[0]}" )/update-generated-config.sh"

diff -Naupr "${ci_operator_dir}" "${workdir}/ci-operator"