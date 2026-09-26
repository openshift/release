#!/usr/bin/env bash

# Remove what bgp-cloud-connector-estate-create built, in the order
# Azure will accept, and say honestly what could not be removed.
#
# A post step rather than a test step, because a test step that never
# runs leaves a Route Server behind, and a Route Server holds the
# subnet, which holds the virtual network, which the group delete then
# cannot remove. It also runs after a cancellation.
#
# Whatever deletes the resource group afterwards is the backstop for
# anything missed here, but a delete that fails is reported rather than
# glossed: "gone" printed over a failure is how a leak becomes
# invisible.

# errexit off explicitly, rather than merely left alone. These commands
# are wrapped before they run, set -uo pipefail does not clear -e if
# that wrapper set it, and one failed removal would then abandon the
# rest. A subnet that cannot go is no reason to leave a Route Server
# running.
set +e
set -uo pipefail

# Defaulted here as well as in the ref, so that set -u cannot end the
# step on a variable the ref would normally have injected.
: "${USE_HYPERSHIFT_AZURE_CREDS:=false}"

AZURE_CONFIG_DIR="$(mktemp -d)"
export AZURE_CONFIG_DIR

redact() {
  sed -E 's/[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}/<guid>/g'
}

az_login() {
  local creds="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json" err rc=0
  if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
    creds="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
  fi
  if [[ ! -f "${creds}" ]]; then
    echo "no Azure credentials at the expected location"
    return 1
  fi
  err="$(mktemp)"
  # --password=VALUE, not --password VALUE. A client secret beginning
  # with a hyphen is read by az as another flag.
  az login --service-principal \
    --username "$(jq -er .clientId "${creds}")" \
    --password="$(jq -er .clientSecret "${creds}")" \
    --tenant "$(jq -er .tenantId "${creds}")" \
    --output none 2>"${err}" || rc=$?
  if (( rc == 0 )); then
    az account set --subscription "$(jq -er .subscriptionId "${creds}")" 2>>"${err}" || rc=$?
  fi
  if (( rc != 0 )); then
    echo "could not log in:"
    redact <"${err}" | sed 's/^/  /'
  fi
  rm -f "${err}"
  return "${rc}"
}

failures=0
removal_failed() {
  echo "    COULD NOT REMOVE: $1"
  redact <"$2" | sed 's/^/      /'
  failures=$((failures + 1))
}

if [[ ! -f "${SHARED_DIR}/bgp-cloud-connector-estate" ]]; then
  echo "nothing was recorded, so there is nothing to remove"
  exit 0
fi

az_login || exit 1

# shellcheck disable=SC1091
source "${SHARED_DIR}/bgp-cloud-connector-estate"
: "${NET_RG:=}" "${VNET:=}" "${ROUTE_SERVER:=}" "${ROUTE_SERVER_PIP:=}"
if [[ -z "${NET_RG}" || -z "${ROUTE_SERVER}" || -z "${VNET}" ]]; then
  echo "the record of what was built is incomplete; leaving it to the group delete"
  exit 1
fi

echo "=== BGP connections ==="
# The operator makes these, so they are removed here rather than there:
# a Route Server with a peering still attached refuses to go.
peerings="$(az network routeserver peering list -g "${NET_RG}" \
  --routeserver "${ROUTE_SERVER}" --query "[].name" -o tsv 2>/dev/null)"
if [[ -z "${peerings}" ]]; then
  echo "  none"
else
  while read -r peering; do
    [[ -z "${peering}" ]] && continue
    err="$(mktemp)"
    if az network routeserver peering delete -g "${NET_RG}" \
         --routeserver "${ROUTE_SERVER}" -n "${peering}" --yes --output none 2>"${err}"; then
      echo "  ${peering}: removed"
    else
      removal_failed "peering ${peering}" "${err}"
    fi
    rm -f "${err}"
  done <<<"${peerings}"
fi

echo
echo "=== the Route Server ==="
started="${SECONDS}"
if ! az network routeserver show -g "${NET_RG}" -n "${ROUTE_SERVER}" --output none 2>/dev/null; then
  echo "  not there"
else
  err="$(mktemp)"
  # AnotherOperationInProgress is a wait, not a refusal. The operator
  # reconciles its peerings on a short loop, so a delete issued while one
  # is in flight is rejected on a resource that is perfectly deletable a
  # moment later. Measured: this took a classic run red after every fact
  # had already been gathered.
  deleted=no
  for attempt in 1 2 3 4 5 6 7 8; do
    if az network routeserver delete -g "${NET_RG}" -n "${ROUTE_SERVER}" \
         --yes --output none 2>"${err}"; then
      deleted=yes
      echo "  gone after $(( (SECONDS - started) / 60 )) minutes, on attempt ${attempt}"
      break
    fi
    grep -q 'AnotherOperationInProgress' "${err}" || break
    echo "  another operation is in progress; waiting (attempt ${attempt})"
    sleep 30
  done
  if [[ "${deleted}" != yes ]]; then
    removal_failed "Route Server ${ROUTE_SERVER}" "${err}"
  fi
  rm -f "${err}"
fi

echo
echo "=== the public address ==="
err="$(mktemp)"
if az network public-ip delete -g "${NET_RG}" -n "${ROUTE_SERVER_PIP}" --output none 2>"${err}"; then
  echo "  removed, or was not there"
else
  removal_failed "public address ${ROUTE_SERVER_PIP}" "${err}"
fi
rm -f "${err}"

echo
echo "=== the subnet ==="
# Last, because the Route Server sat in it.
err="$(mktemp)"
if az network vnet subnet delete -g "${NET_RG}" --vnet-name "${VNET}" \
     -n RouteServerSubnet --output none 2>"${err}"; then
  echo "  removed, or was not there"
else
  removal_failed "RouteServerSubnet in ${VNET}" "${err}"
fi
rm -f "${err}"

echo
echo "=== what is left in ${NET_RG} ==="
az resource list -g "${NET_RG}" --query "[].{name:name,type:type}" -o table 2>&1 | redact | sed 's/^/  /'

echo
if (( failures > 0 )); then
  echo "${failures} thing(s) could not be removed. A Route Server that will not"
  echo "go holds the subnet, which holds the virtual network, and takes the"
  echo "group delete with it."
  exit 1
fi
echo "everything this job built has been removed"
exit 0
