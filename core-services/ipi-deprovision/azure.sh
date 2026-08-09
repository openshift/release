#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function queue() {
  local LIVE="$(jobs | wc -l)"
  while [[ "${LIVE}" -ge 10 ]]; do
    sleep 1
    LIVE="$(jobs | wc -l)"
  done
  echo "${@}"
  "${@}" &
}

function deprovision() {
  WORKDIR="${1}"
  timeout --signal=SIGTERM 30m openshift-install --dir "${WORKDIR}" --log-level error destroy cluster && touch "${WORKDIR}/success" || touch "${WORKDIR}/failure"
}

logdir="${ARTIFACTS}/deprovision"
mkdir -p "${logdir}"

AZURE_AUTH_LOCATION="${AZURE_AUTH_LOCATION:-/azure/osServicePrincipal.json}"
export AZURE_AUTH_LOCATION

# Disable tracing due to credential handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
AZURE_CLIENT_ID="$(jq -r .clientId "${AZURE_AUTH_LOCATION}")"
AZURE_CLIENT_SECRET="$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")"
AZURE_TENANT_ID="$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")"
AZURE_SUBSCRIPTION_ID="$(jq -r .subscriptionId "${AZURE_AUTH_LOCATION}")"

az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none
$WAS_TRACING && set -x

az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
echo "Azure subscription: ${AZURE_SUBSCRIPTION_ID}"

azure_rg_age_cutoff="$(date -u --date="${CLUSTER_TTL}" '+%Y-%m-%dT%H:%M:%SZ')"
echo "deprovisioning clusters with resource groups created before ${azure_rg_age_cutoff} ..."

# List resource groups with creation time via ARM REST API ($expand=createdTime).
rg_json="[]"
next_url="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourcegroups?api-version=2021-04-01&\$expand=createdTime"
while [[ -n "${next_url}" ]]; do
  page="$(az rest --method get --url "${next_url}")"
  rg_json="$(jq -s '.[0] + [.[1].value[] | {name: .name, location: .location, created: .createdTime, state: .properties.provisioningState}]' \
    <(echo "${rg_json}") <(echo "${page}"))"
  next_url="$(echo "${page}" | jq -r '.nextLink // empty')"
done

while IFS=$'\t' read -r rg_name rg_location rg_created rg_state; do
  [[ -z "${rg_name}" ]] && continue
  [[ "${rg_state}" == "Deleting" ]] && continue

  # Match CI-created resource groups: the IPI installer creates resource groups
  # named <infraID>-rg where the infraID starts with "ci-op-" (the CI namespace).
  if [[ ! "${rg_name}" =~ ^ci-op- ]]; then
    continue
  fi

  if [[ "${rg_created}" > "${azure_rg_age_cutoff}" ]]; then
    continue
  fi

  # Derive the infraID from the resource group name by stripping the -rg suffix.
  # If the RG doesn't end in -rg, use the full name as infraID.
  if [[ "${rg_name}" =~ ^(.+)-rg$ ]]; then
    infraID="${BASH_REMATCH[1]}"
  else
    infraID="${rg_name}"
  fi

  workdir="${logdir}/${infraID}"
  mkdir -p "${workdir}"
  cat <<EOF >"${workdir}/metadata.json"
{
  "infraID":"${infraID}",
  "azure":{
    "region":"${rg_location}",
    "resourceGroupName":"${rg_name}",
    "cloudName":"AzurePublicCloud"
  }
}
EOF
  echo "will deprovision Azure cluster ${infraID} in ${rg_location} (rg: ${rg_name}, created: ${rg_created})"
done < <(echo "${rg_json}" | jq -r '.[] | [.name, .location, .created, .state] | @tsv')

# log installer version for debugging purposes
openshift-install version

clusters=$( find "${logdir}" -mindepth 1 -type d )
for workdir in $(shuf <<< ${clusters}); do
  queue deprovision "${workdir}"
done

if ! wait; then
  echo "At least one deprovision job failed or timed out."
fi

# Force-delete resource groups that openshift-install failed to clean up
for workdir in $(find "${logdir}" -mindepth 1 -type d); do
  if [[ -f "${workdir}/failure" ]]; then
    rg_name="$(jq -r '.azure.resourceGroupName' "${workdir}/metadata.json")"
    echo "openshift-install failed for ${rg_name}, force-deleting resource group ..."
    if az group delete --name "${rg_name}" --yes --no-wait; then
      echo "Initiated force-deletion of resource group ${rg_name}"
      rm "${workdir}/failure"
      touch "${workdir}/warning"
    else
      echo "Failed to force-delete resource group ${rg_name}"
    fi
  fi
done

WARNINGS="$(find ${clusters} -name warning -printf '%H\n' | sort)"
if [[ -n "${WARNINGS}" ]]; then
  echo "The following clusters required force-deletion of their resource groups:"
  xargs --max-args 1 basename <<< $WARNINGS
fi

FAILED="$(find ${clusters} -name failure -printf '%H\n' | sort)"
if [[ -n "${FAILED}" ]]; then
  echo "Deprovision failed on the following clusters:"
  xargs --max-args 1 basename <<< $FAILED
  exit 1
fi

echo "Deprovision finished successfully"
