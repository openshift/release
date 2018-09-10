#!/bin/bash

# This script populates ConfigMaps using the configuration
# files in these directories. To be used to bootstrap the
# build cluster after a redeploy.

set -o errexit
set -o nounset
set -o pipefail

config="$( dirname "${BASH_SOURCE[0]}" )/config"

for org_dir in $( find "${config}" -mindepth 1 -maxdepth 1 -type d ); do
	org="$( basename "${org_dir}" )"
	for repo_dir in $( find "${config}/${org}" -mindepth 1 -maxdepth 1 -type d ); do
		repo="$( basename "${repo_dir}" )"
		files=()
		for config_file in $( find "${config}/${org}/${repo}" -mindepth 1 -maxdepth 1 -type f -name "*.yaml" ); do
			files+=( "--from-file=$( basename "${config_file}" )=${config_file}" )
		done
		oc create configmap "ci-operator-${org}-${repo}" "${files[@]}" -o yaml --dry-run | oc apply -f -
	done
done