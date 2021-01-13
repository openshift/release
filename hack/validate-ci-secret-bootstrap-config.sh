#!/bin/bash

# This script ensures that ci-secret-bootstrap config is maintained and up-to-date.

set -o errexit
set -o nounset
set -o pipefail

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

base_dir="${1:-}"

if [[ ! -d "${base_dir}" ]]; then
    echo "Expected a single argument: a path to a directory with release repo layout"
    exit 1
fi

original="${base_dir}/core-services/ci-secret-bootstrap/_config.yaml"
working="${workdir}/_config.yaml"

cp -r "${original}" "${working}"

"${base_dir}/hack/generate-pull-secret-entries.py" "${original}"

if ! diff -u "${original}" "${working}" >"${workdir}/diff"; then
    cat <<EOF
ERROR: This check enforces that the ci-secret-bootstrap config is in sync.

ERROR: To update the config to contain correct pull secret entries, run the following
ERROR: commit the result:

ERROR: $ make ci-secret-bootstrap-config

ERROR: The following differences were found:

EOF
    cat "${workdir}/diff"
    exit 1
fi
