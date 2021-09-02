
#!/bin/bash

# This script ensures that the automated clusterimagesets checked into git are up-to-date.
# If it is not, re-generate the configuration to update it.

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

cp -r "${base_dir}/clusters/hive/pools/" "${workdir}"

clusterimageset-updater --pools "${workdir}/pools" --imagesets "${workdir}/pools"

if ! diff -Naupr "${workdir}/pools" "${base_dir}/clusters/hive/pools/"> "${workdir}/diff"; then
	cat << EOF
ERROR: This check enforces that ClusterImageSet files are generated correctly. We have
ERROR: automation in place that generates these ClusterImageSets and new changes to
ERROR: these ClusterImageSets should occur from a re-generation.

ERROR: Run the following command to update the ClusterImageSets:
ERROR: $ make clusterimagesets

ERROR: The following errors were found:

EOF
	cat "${workdir}/diff"
	exit 1
fi
