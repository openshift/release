#!/bin/bash

# This script populates ConfigMaps using the configuration
# files in these directories. To be used to bootstrap the
# build cluster after a redeploy.

set -o errexit
set -o nounset
set -o pipefail


temp_workdir=$( mktemp -d )
trap "rm -rf ${temp_workdir}" EXIT

function populate_owners() {
	local org="$1"
	local repo="$2"
	local target_dir="${temp_workdir}/${org}/${repo}"
	mkdir -p "${target_dir}"
	git clone --depth 1 --single-branch "git@github.com:${org}/${repo}.git" "${target_dir}"
	if [[ -f "${target_dir}/OWNERS" ]]; then
		cp "${target_dir}/OWNERS" "${jobs}/${org}/${repo}"
		if [[ -d "${config}/${org}/${repo}" ]]; then
			cp "${target_dir}/OWNERS" "${config}/${org}/${repo}"
		fi
	fi
}

jobs="$( dirname "${BASH_SOURCE[0]}" )/jobs"
config="$( dirname "${BASH_SOURCE[0]}" )/config"

for org_dir in $( find "${jobs}" -mindepth 1 -maxdepth 1 -type d ); do
	org="$( basename "${org_dir}" )"
	for repo_dir in $( find "${jobs}/${org}" -mindepth 1 -maxdepth 1 -type d ); do
		repo="$( basename "${repo_dir}" )"
		populate_owners "${org}" "${repo}" &
	done
done

for job in $( jobs -p ); do
	wait "${job}"
done