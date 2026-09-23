#!/bin/bash

# This script ensures that the CI Operator configuration checked into git is up-to-date
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

determinize-ci-operator --config-dir "${ci_operator_dir}/config" --confirm

if ! diff -Naupr "${ci_operator_dir}/config/" "${workdir}/ci-operator/config/"> "${workdir}/diff"; then
	cat << EOF
ERROR: This check enforces that CI Operator configuration YAML files are generated
ERROR: correctly. We have automation in place that updates these configs and
ERROR: new changes to these configurations should be followed with a re-generation.

ERROR: Run the following command to re-generate the CI Operator configurations:
ERROR: $ make ci-operator-config

ERROR: The following errors were found:

EOF
	cat "${workdir}/diff"
	exit 1
fi
