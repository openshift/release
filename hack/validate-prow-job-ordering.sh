#!/bin/bash

# This script ensures that the Prow configuration checked into git has
# deterministic ordering so that bots who modify them submit reasonably
# readable diffs

set -o errexit
set -o nounset
set -o pipefail

workdir="$( mktemp -d )"
trap 'rm -rf "${workdir}"' EXIT

base_dir="${1:-}"

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a single argument: a path to a directory with release repo layout"
  exit 1
fi

jobs_dir="${base_dir}/ci-operator/jobs"

cp -r "${jobs_dir}" "${workdir}"

/bin/bash "$( dirname "${BASH_SOURCE[0]}" )/order-prow-job-config.sh" "${base_dir}"

if ! diff -Naupr -I '^[[:space:]]*#.*' "${workdir}/jobs" "${jobs_dir}"> "${workdir}/diff"; then
  cat << EOF
ERROR: This check enforces Prow Job configuration YAML file format (ordering,
ERROR: linebreaks, indentation) to be consistent over the whole repository. We have
ERROR: automation in place that manipulates these configs and consistent formatting
[ERORR] helps reviewing the changes the automation does.

ERROR: Run the following command to re-format the Prow jobs:
ERROR: $ make jobs

ERROR: The following errors were found:

EOF
  cat "${workdir}/diff"
  exit 1
fi
