#!/bin/bash

# This script ensures that the verified Prow configuration checked into git is up-to-date
# with the tide-config-manager. If it is not, re-generate the configuration to update it.

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

prow_config_dir="${base_dir}/core-services/prow/02_config"
ci_operator_config_dir="${base_dir}/ci-operator/config"
verified_opt_in="${base_dir}/core-services/verified/opt-in.yaml"
verified_opt_out="${base_dir}/core-services/verified/opt-out.yaml"

# Copy the prow config to workdir
cp -r "${prow_config_dir}" "${workdir}/prow-config"

# Run tide-config-manager to generate the verified configuration
tide-config-manager \
  --lifecycle-phase=verified \
  --verified-opt-in="${verified_opt_in}" \
  --verified-opt-out="${verified_opt_out}" \
  --ci-operator-config-dir="${ci_operator_config_dir}" \
  --prow-config-dir="${workdir}/prow-config" \
  --sharded-prow-config-base-dir="${workdir}/prow-config"

# Run determinize-prow-config to format the generated config consistently
determinize-prow-config \
  --prow-config-dir="${workdir}/prow-config" \
  --sharded-prow-config-base-dir="${workdir}/prow-config" \
  --sharded-plugin-config-base-dir="${workdir}/prow-config"

# Compare the generated config with the checked-in version
if ! diff -Naupr "${prow_config_dir}/" "${workdir}/prow-config/" > "${workdir}/diff"; then
	cat << EOF
ERROR: This check enforces that verified Prow configuration is up-to-date with
ERROR: the tide-config-manager. The verified opt-in/opt-out files have been changed
ERROR: but the corresponding Prow configuration has not been regenerated.

ERROR: Run the following command to re-generate the verified configuration:
ERROR: $ make verified-label

ERROR: The following errors were found:

EOF
	cat "${workdir}/diff"
	exit 1
fi
