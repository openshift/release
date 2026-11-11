#!/bin/bash

# Publish main and all of its variants together. Generate in a hidden directory
# on the same filesystem so readers only see complete YAML files after rename.
set -euo pipefail

efs_root="${1:?usage: publish-ci-tools-standalone-jobs.sh EFS_ROOT}"
repo=openshift/ci-tools-standalone
prefix=openshift-ci-tools-standalone-main
destination="${efs_root}/generated/${repo}"

mkdir -p "${efs_root}"
candidate="$(mktemp -d "${efs_root}/..ci-tools-standalone.XXXXXX")"
trap 'rm -rf "${candidate}"' EXIT

shopt -s nullglob
configs=("ci-operator/config/${repo}/${prefix}.yaml" "ci-operator/config/${repo}/${prefix}"__*.yaml)
args=()
for config in "${configs[@]}"; do
  args+=(--from-file "${config}")
done

# Do not pass --managed-repos-config: this publisher owns the enrolled branch.
# The external Prow scheduler assigns execution clusters when jobs are created.
ci-operator-prowgen "${args[@]}" \
  --registry ci-operator/step-registry \
  --to-dir "${candidate}"

mkdir -p "${destination}"
for job_type in presubmits postsubmits periodics; do
  filename="${prefix}-${job_type}.yaml"
  if [[ -f "${candidate}/${repo}/${filename}" ]]; then
    mv -f "${candidate}/${repo}/${filename}" "${destination}/${filename}"
  else
    rm -f "${destination}/${filename}"
  fi
done
