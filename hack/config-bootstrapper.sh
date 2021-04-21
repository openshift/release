#!/bin/bash
set -euo pipefail

dir=$(realpath "$(dirname "${BASH_SOURCE}")/..")
roe_release_dir="${dir}/../../redhat-operator-ecosystem/release"

if ! [[ -d "${roe_release_dir}" ]]; then
  echo "You need to also have a clone of redhat-operator-ecosystem/release in ${roe_release_dir}"
  exit 1
fi


config-bootstrapper \
    --dry-run=false \
    --source-path "${dir}" \
    --source-path "${roe_release_dir}" \
    --config-path "${dir}/core-services/prow/02_config/_config.yaml" \
    --plugin-config "${dir}/core-services/prow/02_config/_plugins.yaml" \
    --supplemental-prow-config-dir="${dir}/core-services/prow/02_config"
