#!/bin/bash

# This script ensures that the configuration is covered by an automatic updater
# shart. If it is not, update the config-updater configuration to upload.

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

if ! config-shard-validator --release-repo-dir="${base_dir}" > "${workdir}/output" 2>&1; then
	cat << EOF
ERROR: This check enforces that configuration YAML files will be uploaded automatically
ERROR: as they change. You are adding a file that is not covered by the automatic upload.
ERROR: See the following page for more details:

https://docs.ci.openshift.org/docs/how-tos/contributing-openshift-release/#ci-operator-configuration-sharding

ERROR: The following errors were found:

EOF
	cat "${workdir}/output"
	exit 1
fi
