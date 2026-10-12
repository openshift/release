#!/bin/bash

# This script ensures that the step registry's metadata is up-to-date

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

step_registry_dir="${base_dir}/ci-operator/step-registry"

cp -r "${step_registry_dir}" "${workdir}"

generate-registry-metadata --registry="${workdir}/step-registry"

if ! diff -Naupr "${step_registry_dir}" "${workdir}/step-registry"> "${workdir}/diff"; then
	cat << EOF
ERROR: This check enforces that the step registry metadata is generated correctly.
ERROR: We have automation in place that generates this metadata and new changes to
ERROR: the metadata should occur from a re-generation.

ERROR: Run the following command to re-generate the registry metadata:
ERROR: $ make registry-metadata

ERROR: The following errors were found:

EOF
	cat "${workdir}/diff"
	exit 1
fi
