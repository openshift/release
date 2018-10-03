#!/bin/bash

# This script populates the ci-operator-configs configMap using 
# the configuration files in these directories. To be used to bootstrap the
# build cluster after a redeploy.

set -o errexit
set -o nounset
set -o pipefail

config="$( dirname "${BASH_SOURCE[0]}" )/config"

function populate_configmap() {
	local org=$1
	local repo=$2

	for config_file in $( find "${config}/${org}/${repo}" -mindepth 1 -maxdepth 1 -type f -name "*.yaml" ); do
		files+=( "--from-file=$(basename ${config_file})=${config_file}" )
	done
}

if [[ -n "${ORG:-}" && -n "${REPO:-}" ]]; then
	populate_configmap "${ORG}" "${REPO}"
	exit
fi

if [[ -n "${ORG:-}" && -z "${REPO:-}" ]]; then
	for repo_dir in $( find "${config}/${ORG}" -mindepth 1 -maxdepth 1 -type d ); do
		repo="$( basename "${repo_dir}" )"
		populate_configmap "${ORG}" "${repo}"
	done
	exit
fi

for org_dir in $( find "${config}" -mindepth 1 -maxdepth 1 -type d ); do
	org="$( basename "${org_dir}" )"
	for repo_dir in $( find "${config}/${org}" -mindepth 1 -maxdepth 1 -type d ); do
		repo="$( basename "${repo_dir}" )"
		populate_configmap "${org}" "${repo}"
	done
done

# Update the configMap
oc create configmap ci-operator-configs "${files[@]}" -o yaml --dry-run | oc apply -f -