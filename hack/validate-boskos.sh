#!/bin/bash

# This script ensures that the Boskos configuration checked into git is up-to-date
# with the generator. If it is not, re-generate the configuration to update it.

set -o errexit
set -o nounset
set -o pipefail

base_dir=.

cd "${base_dir}/core-services/prow/02_config"
ORIGINAL="$(cat _boskos.yaml)"
./generate-boskos.py
DIFF="$(diff -u <(echo "${ORIGINAL}") _boskos.yaml || true)"
if test -n "${DIFF}"
then
	cat << EOF
ERROR: This check enforces that the Boskos configuration is generated
ERROR: correctly. We have automation in place that updates the configuration and
ERROR: new changes to the configuration should be followed with a re-generation.

ERROR: Run the following command to re-generate the Boskos configuration:
ERROR: $ make boskos-config

ERROR: The following errors were found:

EOF
	echo "${DIFF}"
	exit 1
fi
