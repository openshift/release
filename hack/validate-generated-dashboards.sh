#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

base_dir="${1:-}"

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a single argument: a path to a directory with release repo layout"
  exit 1
fi

jb --version

mixins_dir="${base_dir}/clusters/app.ci/prow-monitoring/mixins"

make -C "${mixins_dir}" validate
