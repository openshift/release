#!/bin/bash

# Delete the Azure AD application created for the ARO cluster.
# az aro delete does not delete the application, so we must clean it up manually.

set -o nounset
set -o pipefail

sp="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
az login --service-principal -u "$(jq -r .clientId "${sp}")" \
  -p "$(jq -r .clientSecret "${sp}")" --tenant "$(jq -r .tenantId "${sp}")" --output none

# An interrupted provision step may not pass the app ID to SHARED_DIR,
# so fall back to looking it up by the cluster name.
id_file="${SHARED_DIR}/aro-cluster-app-id"
if [[ -s "${id_file}" ]]; then
  ids="$(<"${id_file}")"
else
  name="${NAMESPACE}-${UNIQUE_HASH}"
  # --display-name matches by prefix; keep only the exact name.
  ids="$(az ad app list --display-name "${name}" --query "[?displayName=='${name}'].appId" -o tsv)"
  if [[ -z "${ids}" ]]; then
    echo "No application was recorded or found by name, so there is nothing to delete"
    exit 0
  fi
  echo "No application was recorded; found $(wc -l <<<"${ids}") by name"
fi

failed=0
while read -r id; do
  deleted=false
  for attempt in $(seq 1 6); do
    if az ad app delete --id "${id}"; then
      echo "Deleted the cluster's application on attempt ${attempt}"
      deleted=true
      break
    fi
    sleep 10
  done
  [[ "${deleted}" == true ]] || failed=1
done <<<"${ids}"

if (( failed )); then
  echo "Could not delete the cluster's application" >&2
  exit 1
fi
