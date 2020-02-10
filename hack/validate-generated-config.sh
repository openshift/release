#!/bin/bash

# This script ensures that the Prow configuration checked into git is up-to-date
# with the generator. If it is not, re-generate the configuration to update it.

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

ci_operator_dir="${base_dir}/ci-operator"

cp -r "${ci_operator_dir}" "${workdir}"

ci-operator-prowgen --from-dir "${ci_operator_dir}/config" --to-dir "${workdir}/ci-operator/jobs"

if ! diff -Naupr "${ci_operator_dir}/jobs/" "${workdir}/ci-operator/jobs/"> "${workdir}/diff"; then
	cat << EOF
ERROR: This check enforces that Prow Job configuration YAML files are generated
ERROR: correctly. We have automation in place that generates these configs and
ERROR: new changes to these job configurations should occur from a re-generation.

ERROR: Run the following command to re-generate the Prow jobs:
ERROR: $ make jobs

ERROR: The following errors were found:

EOF
	cat "${workdir}/diff"
	exit 1
fi
