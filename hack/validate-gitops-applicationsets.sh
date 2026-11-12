#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

base_dir="${1:-}"
if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a single argument: path to openshift/release checkout"
  exit 1
fi

python3 "${base_dir}/hack/generators/gitops/generate-applicationsets.py" --verify "${base_dir}"
