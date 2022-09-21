#!/bin/bash

# This script ensures that the Prow configuration checked into git is formatted
# as it would be if generated. If it is not, re-generate the configuration to update it.

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

prow_config_dir="${base_dir}/core-services/prow/02_config/"

cp -r "${prow_config_dir}"* "${workdir}"

determinize-prow-config --prow-config-dir "${workdir}" --sharded-prow-config-base-dir "${workdir}" --sharded-plugin-config-base-dir "${workdir}"


if ! diff -Naupr "${prow_config_dir}" "${workdir}"> "${workdir}/diff"; then
	cat << EOF
ERROR: This check enforces that Prow configuration YAML files are formatted
ERROR: correctly. We have automation in place that generates these configs and
ERROR: new changes to these job configurations should occur from a re-generation.

ERROR: Run the following command to re-generate the Prow jobs:
ERROR: $ make prow-config

ERROR: The following errors were found:

EOF
	cat "${workdir}/diff"
	exit 1
fi
