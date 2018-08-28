#!/bin/bash

# This script ensures that the Prow configuration checked into git is up-to-date
# with the generator. If it is not, re-generate the configuration to update it.

set -o errexit
set -o nounset
set -o pipefail

workdir="$( mktemp -d )"
trap 'rm -rf "${workdir}"' EXIT

ci_operator_dir="$( dirname "${BASH_SOURCE[0]}" )/../ci-operator"

cp -r "${ci_operator_dir}" "${workdir}"

"$( dirname "${BASH_SOURCE[0]}" )/update-generated-config.sh"

if ! diff -Naupr "${ci_operator_dir}" "${workdir}/ci-operator"> "${workdir}/diff"; then
  cat << EOF
[ERROR] This check enforces that Prow Job configuration YAML files are generated
[ERROR] correctly. We have automation in place that generates these configs and
[ERROR] new changes to these job configurations should occur from a re-generation.

[ERROR] Run the following command to re-generate the Prow jobs:
[ERROR] $ docker run -it -v \$(pwd)/ci-operator:/ci-operator:z registry.svc.ci.openshift.org/ci/ci-operator-prowgen:latest --config-dir /ci-operator/config --prow-jobs-dir /ci-operator/jobs

[ERROR] The following errors were found:

EOF
  cat "${workdir}/diff"
fi
