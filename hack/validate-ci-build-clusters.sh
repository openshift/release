#!/bin/bash

workdir="$( mktemp -d )"
trap 'rm -rf "${workdir}"' EXIT

base_dir="${1:-}"

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a single argument: a path to a directory with release repo layout"
  exit 1
fi

cp -r "${base_dir}"* "${workdir}"

cluster-init -release-repo="${workdir}" -create-pr=false -update=true

declare -a files=(
              "/clusters/build-clusters"
              "/ci-operator/jobs/openshift/release"
              "/core-services/ci-secret-bootstrap"
              "/core-services/ci-secret-generator"
              "/core-services/sanitize-prow-jobs"
)
exitCode=0
for i in "${files[@]}"
do
  if ! diff -Naupr "${base_dir}$i" "${workdir}$i" > "${workdir}$i/diff"; then
    echo ERROR: The configuration in "$i" does not match the expected generated configuration, diff:
    cat "${workdir}$i/diff" #TODO: why is this printing the diff twice???
    exitCode=1
  fi
done

exit $exitCode
