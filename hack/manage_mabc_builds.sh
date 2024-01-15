#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

declare -A mabcs
mabcs["managed-clonerefs"]="clusters/build-clusters/multi01/supplemental-ci-images/001_managed-clonerefs_mabc.yaml"
mabcs["ci-tools-build-root"]="clusters/build-clusters/multi01/supplemental-ci-images/002_ci-tools-build-root-mabc.yaml"

for mabc in "${!mabcs[@]}"; do
  mabc_name="$mabc"
  mabc_path="${mabcs[${mabc}]}"

  multiarch_build="$(oc -n ci get "mabc/$mabc_name" -o json)"
  
  if [ -z "$(jq -r '.status.state' <<<$multiarch_build)" ]; then
    echo "mabc/$mabc_name is running already"
    continue
  fi

  oc -n ci delete --cascade=foreground --wait=true "mabc/$mabc_name"
  echo "mabc/$mabc_name deleted"

  oc -n ci apply --wait=true -f "$mabc_path"
  echo "mabc/$mabc_name created"

  oc -n ci wait --for=jsonpath='{.status.state}'=success --timeout=5m "mabc/$mabc_name"
  echo "waiting for mabc/$mabc_name to complete"
done