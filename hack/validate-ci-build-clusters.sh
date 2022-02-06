#!/bin/bash

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

cp -r "${base_dir}/"* "${workdir}"

cluster-init -release-repo="${workdir}" -create-pr=false -update=true

declare -a files=(
              "/clusters/build-clusters"
              "/ci-operator/jobs/openshift/release"
              "/core-services/ci-secret-bootstrap"
              "/core-services/ci-secret-generator"
              "/core-services/sanitize-prow-jobs"
              "/core-services/sync-rover-groups"
)
exitCode=0
for i in "${files[@]}"
do
  if ! diff -Naupr "${base_dir}$i" "${workdir}$i" > "${workdir}/diff"; then
    echo ERROR: The configuration in "$i" does not match the expected generated configuration, diff:
    cat "${workdir}/diff"
    exitCode=1
  fi
done

if [ "$exitCode" = 1 ]; then
  echo ERROR: Run the following command to update the build cluster configs:
  echo ERROR: $ make update-ci-build-clusters
fi

exit "$exitCode"
