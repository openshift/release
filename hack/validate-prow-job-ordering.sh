#!/bin/bash

# This script ensures that the Prow configuration checked into git has
# deterministic ordering so that bots who modify them submit reasonably
# readable diffs

set -x
set -o errexit
set -o nounset
set -o pipefail

workdir="$( mktemp -d )"
# trap 'rm -rf "${workdir}"' EXIT

jobs_dir="$( dirname "${BASH_SOURCE[0]}" )/../ci-operator/jobs"

cp -r "${jobs_dir}" "${workdir}"

"$( dirname "${BASH_SOURCE[0]}" )/order-prow-job-config.sh"

diff -Naupr "${jobs_dir}" "${workdir}/jobs"
