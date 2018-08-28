#!/bin/bash

# This script ensures that the Prow configuration checked into git has
# deterministic ordering so that bots who modify them submit reasonably
# readable diffs

set -o errexit
set -o nounset
set -o pipefail

workdir="$( mktemp -d )"
# trap 'rm -rf "${workdir}"' EXIT

jobs_dir="$( dirname "${BASH_SOURCE[0]}" )/../ci-operator/jobs"

cp -r "${jobs_dir}" "${workdir}"

"$( dirname "${BASH_SOURCE[0]}" )/order-prow-job-config.sh"

if ! diff -Naupr "${workdir}/jobs" "${jobs_dir}"> "${workdir}/diff"; then
  cat << EOF
[ERROR] This check enforces Prow Job configuration YAML file format (ordering,
[ERROR] linebreaks, indentation) to be consistent over the whole repository. We have
[ERROR] automation in place that manipulates these configs and consistent formatting
[ERORR] helps reviewing the changes the automation does.

[ERROR] Please apply the following changes to your Prow job configuration:

EOF
  cat "${workdir}/diff"
fi
