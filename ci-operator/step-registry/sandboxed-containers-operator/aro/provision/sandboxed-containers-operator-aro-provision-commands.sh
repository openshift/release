#!/bin/bash

# Custom ARO provision step that creates a dedicated Azure AD application
# for the cluster to avoid the InvalidServicePrincipalCredentials error.
# Based on openshift/bgp-cloud-connector approach (commit 94799a6e58b).

set -o nounset
set -o errexit
set -o pipefail

CLUSTER="${NAMESPACE}-${UNIQUE_HASH}"
RESOURCEGROUP="$(<"${SHARED_DIR}/resourcegroup")"
VNET="$(<"${SHARED_DIR}/vnet")"
LOCATION="${LEASED_RESOURCE}"
PULL_SECRET_FILE="${CLUSTER_PROFILE_DIR}/pull-secret"
sp="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"

echo "${CLUSTER}" >"${SHARED_DIR}/cluster-name"
echo "${LOCATION}" >"${SHARED_DIR}/location"

echo "az-cli version information"
az version

az cloud set --name AzureCloud
az login --service-principal -u "$(jq -r .clientId "${sp}")" \
  -p "$(jq -r .clientSecret "${sp}")" --tenant "$(jq -r .tenantId "${sp}")" --output none

for provider in Microsoft.RedHatOpenShift Microsoft.Compute Microsoft.Storage Microsoft.Authorization; do
  az provider register -n "${provider}" --wait
done

# Create the cluster's Azure AD application
app_id="$(az ad app create --display-name "${CLUSTER}" --query appId -o tsv)"
# Record before anything can fail, so cleanup step can find it
echo "${app_id}" >"${SHARED_DIR}/aro-cluster-app-id"
echo "Created the cluster's application: ${app_id}"

redact() {
  sed -E 's/[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}/<guid>/g'
}

# Add password with retry (Graph API can be unreliable)
err="$(mktemp)"
client_secret=""
for attempt in $(seq 1 18); do
  if client_secret="$(az ad app credential reset --id "${app_id}" --query password -o tsv 2>"${err}")" \
     && [[ -n "${client_secret}" ]]; then
    echo "Added password on attempt ${attempt}"
    break
  fi
  client_secret=""
  reason="$(grep -oE 'Request_ResourceNotFound|Insufficient privileges|Authorization_RequestDenied' "${err}" | head -1 || true)"
  echo "Attempt ${attempt}: ${reason:-$(grep -m1 . "${err}" | redact)}"
  sleep 10
done
if [[ -z "${client_secret}" ]]; then
  echo "Could not add password to the cluster's application; last error:" >&2
  redact <"${err}" | head -5 >&2
  exit 1
fi

# Create service principal and wait for it to become visible
# (az aro create needs to look it up before creating the cluster)
sp_id=""
for attempt in $(seq 1 18); do
  sp_id="$(az ad sp list --filter "appId eq '${app_id}'" --query '[0].id' -o tsv 2>/dev/null || true)"
  if [[ -n "${sp_id}" ]]; then
    echo "Service principal is visible on attempt ${attempt}"
    break
  fi
  if ! az ad sp create --id "${app_id}" --output none 2>"${err}"; then
    reason="$(grep -oE 'Request_ResourceNotFound|Insufficient privileges|Authorization_RequestDenied|already exists' "${err}" | head -1 || true)"
    echo "Creating service principal, attempt ${attempt}: ${reason:-$(grep -m1 . "${err}" | redact)}"
  fi
  sleep 10
done
if [[ -z "${sp_id}" ]]; then
  echo "The cluster's service principal never became visible; last error:" >&2
  redact <"${err}" | head -5 >&2
  exit 1
fi

# Build az aro create command
create=(az aro create --resource-group "${RESOURCEGROUP}" --name "${CLUSTER}" --vnet "${VNET}"
  --master-subnet master-subnet --worker-subnet worker-subnet --client-id "${app_id}")
if [[ -f "${PULL_SECRET_FILE}" ]]; then
  create+=(--pull-secret "@${PULL_SECRET_FILE}")
fi

# Handle ARO_WORKER_VM_SIZE
if [[ -n "${ARO_WORKER_VM_SIZE:-}" ]]; then
  create+=(--worker-vm-size "${ARO_WORKER_VM_SIZE}")
fi

# Handle ARO_WORKER_COUNT
if [[ -n "${ARO_WORKER_COUNT:-}" ]]; then
  create+=(--worker-count "${ARO_WORKER_COUNT}")
fi

# Handle ARO_CLUSTER_VERSION with auto-selection
if [[ -n "${ARO_CLUSTER_VERSION}" ]]; then
  echo "Available versions in ${LOCATION}:"
  az aro get-versions -l "${LOCATION}" -o table
  version="${ARO_CLUSTER_VERSION}"
  if [[ "${version}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    version="$(az aro get-versions -l "${LOCATION}" -o json | jq -r '.[]' | grep "^${version}\." | sort -V | tail -1)"
    if [[ -z "${version}" ]]; then
      echo "No versions found matching ${ARO_CLUSTER_VERSION}.x" >&2
      exit 1
    fi
  fi
  echo "Using ARO version ${version}"
  create+=(--version "${version}")
fi

# Handle ARO_BYO_NSG
if [[ "${ARO_BYO_NSG:-false}" == "true" ]]; then
  create+=(--enable-preconfigured-nsg)
fi

echo "Running: ${create[*]} --client-secret <redacted>"
"${create[@]}" --client-secret "${client_secret}" >"${SHARED_DIR}/clusterinfo"

echo "Cluster created, sleeping 600 seconds"
sleep 600

echo "Retrieving credentials"
KUBEAPI="$(jq -r '.apiserverProfile.url' "${SHARED_DIR}/clusterinfo")"
KUBECRED="$(az aro list-credentials --name "${CLUSTER}" --resource-group "${RESOURCEGROUP}")"
KUBEUSER="$(jq -r '.kubeadminUsername' <<<"${KUBECRED}")"
KUBEPASS="$(jq -r '.kubeadminPassword' <<<"${KUBECRED}")"
echo "${KUBECRED}" >"${SHARED_DIR}/clustercreds"

echo "Logging into the cluster"
oc login "${KUBEAPI}" --username="${KUBEUSER}" --password="${KUBEPASS}" --insecure-skip-tls-verify=true

echo "Generating kubeconfig in ${SHARED_DIR}/kubeconfig"
oc config view --raw >"${SHARED_DIR}/kubeconfig"
