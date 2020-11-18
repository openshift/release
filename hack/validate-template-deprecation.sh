#!/bin/bash

# This script ensures that template deprecation allowlist is maintained up-to-date.

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

original="${base_dir}/core-services/template-deprecation/_allowlist.yaml"
working="${workdir}/_allowlist.yaml"

cp -r "${original}" "${working}"

template-deprecator --prow-jobs-dir "${base_dir}"/ci-operator/jobs \
    --prow-config-path "${base_dir}"/core-services/prow/02_config/_config.yaml \
    --prow-plugin-config-path "${base_dir}"/core-services/prow/02_config/_plugins.yaml \
    --allowlist-path "${working}"

if ! diff -u "${original}" "${working}" >"${workdir}/diff"; then
    cat <<EOF
ERROR: This check enforces that CI jobs using templates are tracked in an allowlist.
ERROR: For more information about template deprecation, see:
ERROR: https://docs.ci.openshift.org/docs/how-tos/migrating-template-jobs-to-multistage/

ERROR: To update the allowlist to contain newly added jobs run the following and
ERROR: commit the result:

ERROR: $ make template-allowlist

ERROR: The following differences were found:

EOF
    cat "${workdir}/diff"
    exit 1
fi
