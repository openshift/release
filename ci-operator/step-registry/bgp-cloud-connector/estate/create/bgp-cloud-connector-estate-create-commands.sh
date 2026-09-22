#!/usr/bin/env bash

# Build the Route Server the operator discovers, from the release
# repository rather than from the operator's own hack scripts. That
# repository cannot take the changes an ARO job would need, so an ARO
# job has to stand its estate up from here.
#
# Only the Route Server is built. The BGP connections to the router
# nodes are the operator's job.
#
# It reports rather than fails. A step that stops at its first
# unanswerable question gathers one fact where it could have gathered
# twenty, and the point is to need one rehearsal rather than several.
# What was built is recorded before anything is built, so a step that
# dies halfway still leaves something the teardown can remove.

# errexit off explicitly, rather than merely left alone. These commands
# are wrapped before they run, set -uo pipefail does not clear -e if
# that wrapper set it, and a bare command that fails would then abandon
# the step where it stands. Measured: one Forbidden ended a step after
# a single line, before the echo on the next line.
set +e
set -uo pipefail

# Defaulted here as well as in the ref, so that set -u cannot end the
# step on a variable the ref would normally have injected. A step
# that dies on an unset name gathers nothing at all.
: "${ROUTE_SERVER_NAME:=bgp-cloud-connector-rs}"
: "${ROUTE_SERVER_SUBNET_PREFIX:=10.0.4.0/27}"
: "${USE_HYPERSHIFT_AZURE_CREDS:=false}"

AZURE_CONFIG_DIR="$(mktemp -d)"
export AZURE_CONFIG_DIR

redact() {
  sed -E 's/[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}/<guid>/g'
}

section() { echo; echo "=== $* ==="; }

# Logging in is both the call most likely to fail and the one whose
# failure text is most likely to name the tenant, the principal, the
# subscription or the request. Prow logs are public for openshift
# repositories, so it is captured and redacted like everything else.
#
# The credential follows the convention azure-provision-resourcegroup
# and azure-provision-vnet-hypershift already use, so this step reaches
# the group those steps created whichever job it runs in.
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
  # with a hyphen is read by az as another flag, and the login fails
  # with "argument --password/-p: expected one argument" for a secret
  # that is perfectly good.
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

az_login || exit 0

section "where the virtual network is"
# Which file holds it depends on the job.
#   ARO classic: azure-provision-resourcegroup makes one group and
#     aro-provision-vnet puts the virtual network in it by name.
#   ARO HCP: azure-provision-vnet-hypershift gives the network a group
#     of its own and records that group and the network's id.
net_rg=""
if [[ -s "${SHARED_DIR}/resourcegroup_vnet" ]]; then
  net_rg="$(<"${SHARED_DIR}/resourcegroup_vnet")"
elif [[ -s "${SHARED_DIR}/resourcegroup" ]]; then
  net_rg="$(<"${SHARED_DIR}/resourcegroup")"
fi

vnet=""
if [[ -s "${SHARED_DIR}/azure_vnet_id" ]]; then
  vnet="$(basename "$(<"${SHARED_DIR}/azure_vnet_id")")"
elif [[ -s "${SHARED_DIR}/vnet" ]]; then
  vnet="$(<"${SHARED_DIR}/vnet")"
fi
# Asked of Azure only when no step recorded it, so that a job shape
# nobody anticipated still reaches a virtual network if one is there.
if [[ -z "${vnet}" && -n "${net_rg}" ]]; then
  vnet="$(az network vnet list -g "${net_rg}" --query "[0].name" -o tsv 2>/dev/null)"
fi

if [[ -z "${net_rg}" || -z "${vnet}" ]]; then
  echo "  no virtual network in ${net_rg:-<no group>}; nothing can be built here"
  exit 0
fi
echo "  group ${net_rg}"
echo "  network ${vnet}"
az network vnet show -g "${net_rg}" -n "${vnet}" \
  --query "{addressSpace: addressSpace.addressPrefixes, subnets: subnets[].{name:name, prefix:addressPrefix}}" \
  -o json 2>&1 | redact | sed 's/^/  /'

pip="${ROUTE_SERVER_NAME}-pip"

# Written before anything exists, so the teardown can remove a Route
# Server this step was killed in the middle of creating. The teardown
# treats every absence as success, so naming something that was never
# built costs it a read.
{
  echo "NET_RG=${net_rg}"
  echo "VNET=${vnet}"
  echo "ROUTE_SERVER=${ROUTE_SERVER_NAME}"
  echo "ROUTE_SERVER_PIP=${pip}"
} >"${SHARED_DIR}/bgp-cloud-connector-estate"

section "the subnet"
# The name is fixed: Azure hosts a Route Server only in a subnet called
# RouteServerSubnet. The default prefix is free in both networks these
# jobs meet -- the classic 10.0.0.0/17 puts masters and workers in the
# first two /23s, and the HCP 10.0.0.0/16 has one /24 at the bottom --
# and an added prefix that overlaps one the network already has is
# refused, so it is a parameter rather than a constant.
if az network vnet subnet show -g "${net_rg}" --vnet-name "${vnet}" \
     -n RouteServerSubnet --output none 2>/dev/null; then
  echo "  already there"
elif az network vnet subnet create -g "${net_rg}" --vnet-name "${vnet}" \
       -n RouteServerSubnet --address-prefixes "${ROUTE_SERVER_SUBNET_PREFIX}" \
       --output none 2>&1 | redact | sed 's/^/  /'; then
  echo "  created ${ROUTE_SERVER_SUBNET_PREFIX}"
else
  echo "  could not create RouteServerSubnet, so there is nowhere to put a Route Server"
  exit 0
fi

subnet_id="$(az network vnet subnet show -g "${net_rg}" --vnet-name "${vnet}" \
  -n RouteServerSubnet --query id -o tsv 2>/dev/null)"
if [[ -z "${subnet_id}" ]]; then
  echo "  the subnet exists but has no readable id; stopping here"
  exit 0
fi

section "the public address"
# Standard SKU and a static allocation, because a Route Server takes
# nothing else.
if az network public-ip show -g "${net_rg}" -n "${pip}" --output none 2>/dev/null; then
  echo "  already there"
elif az network public-ip create -g "${net_rg}" -n "${pip}" \
       --sku Standard --allocation-method Static --version IPv4 --output none 2>&1 \
       | redact | sed 's/^/  /'; then
  echo "  created"
else
  echo "  could not create the public address"
  exit 0
fi

section "the Route Server"
# Twenty minutes is normal.
started="${SECONDS}"
if az network routeserver show -g "${net_rg}" -n "${ROUTE_SERVER_NAME}" --output none 2>/dev/null; then
  echo "  already there"
elif az network routeserver create -g "${net_rg}" -n "${ROUTE_SERVER_NAME}" \
       --hosted-subnet "${subnet_id}" --public-ip-address "${pip}" \
       --output none 2>&1 | redact | sed 's/^/  /'; then
  echo "  created in $(( (SECONDS - started) / 60 )) minutes"
else
  echo "  could not create the Route Server after $(( (SECONDS - started) / 60 )) minutes"
  exit 0
fi

section "what it says about itself"
# virtualRouterIps are the addresses the operator hands to FRR as
# neighbours, and virtualRouterAsn is the far side's AS number, which
# Azure fixes and offers no flag to change.
az network routeserver show -g "${net_rg}" -n "${ROUTE_SERVER_NAME}" --query "{
  provisioningState: provisioningState,
  virtualRouterAsn: virtualRouterAsn,
  virtualRouterIps: virtualRouterIps,
  allowBranchToBranchTraffic: allowBranchToBranchTraffic
}" -o json 2>&1 | redact | sed 's/^/  /'
az network routeserver show -g "${net_rg}" -n "${ROUTE_SERVER_NAME}" -o json 2>/dev/null \
  | redact >"${ARTIFACT_DIR}/routeserver.json"

# Only now, so that a step reading this knows a Route Server is there
# rather than that one was attempted.
echo "ROUTE_SERVER_BUILT=yes" >>"${SHARED_DIR}/bgp-cloud-connector-estate"

section "done"
exit 0
