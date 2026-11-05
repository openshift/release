#!/usr/bin/env bash

# Never emit commands or credential-bearing arguments through shell tracing,
# including when the caller invokes this script with `bash -x`.
set +x
set -o errexit
set -o nounset
set -o pipefail

trap 'children=$(jobs -p); if [[ -n "${children}" ]]; then kill ${children} 2>/dev/null || true; wait ${children} 2>/dev/null || true; fi' TERM INT

if [[ ! "${MP_REPLICAS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "MP_REPLICAS must be a positive integer." >&2
  exit 1
fi

STATE_FILE="${SHARED_DIR}/aro-hcp.env"
if [[ -s "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi
CLUSTER_CONFIG_FILE="${SHARED_DIR}/cluster-config"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-${AZURE_SUBSCRIPTION_ID:-}}"

: "${CLUSTER_NAME:?SHARED_DIR/aro-hcp.env must provide the cluster name}"
: "${CUSTOMER_RG_NAME:?SHARED_DIR/aro-hcp.env must provide the resource group}"

record_nodepool_timer() {
  local nodepool="$1"
  local key="$2"
  local value="$3"
  local tmp
  if [[ ! -s "${CLUSTER_CONFIG_FILE}" ]] || ! jq empty "${CLUSTER_CONFIG_FILE}" >/dev/null 2>&1; then
    jq -n '{provider: "azure", cluster: {}, timers: {}, nodepools: {}}' > "${CLUSTER_CONFIG_FILE}.tmp"
    mv "${CLUSTER_CONFIG_FILE}.tmp" "${CLUSTER_CONFIG_FILE}"
    chmod 600 "${CLUSTER_CONFIG_FILE}"
  fi
  tmp=$(mktemp "${CLUSTER_CONFIG_FILE}.XXXXXX")
  jq --arg nodepool "${nodepool}" --arg key "${key}" --argjson value "${value}" \
    '.nodepools[$nodepool][$key] = $value' "${CLUSTER_CONFIG_FILE}" > "${tmp}"
  mv "${tmp}" "${CLUSTER_CONFIG_FILE}"
}

export AZURE_CONFIG_DIR="${SHARED_DIR}/azure-config-nodepool"
mkdir -p "${AZURE_CONFIG_DIR}"
umask 077

SP_FILE="${CLUSTER_PROFILE_DIR}/osServicePrincipal--dot--json"
if [[ ! -s "${SP_FILE}" ]]; then
  echo "${SP_FILE} is missing; cannot authenticate for node-pool creation." >&2
  exit 1
fi

AZURE_CLIENT_ID=$(jq -er '.clientId' "${SP_FILE}")
AZURE_CLIENT_SECRET=$(jq -er '.clientSecret' "${SP_FILE}")
AZURE_TENANT_ID=$(jq -er '.tenantId' "${SP_FILE}")

set +x
az login \
  --service-principal \
  --username "${AZURE_CLIENT_ID}" \
  --password "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --only-show-errors \
  --output none
unset AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID

if [[ -n "${SUBSCRIPTION_ID}" ]]; then
  az account set --subscription "${SUBSCRIPTION_ID}"
else
  SUBSCRIPTION_ID=$(az account show --query id --output tsv)
fi

az extension add --name aro --upgrade --yes --only-show-errors
az aro hcp -h >/dev/null

# The HCP resource reports the control-plane minor version, while node pools
# require a full X.Y.Z version. Prefer the existing workers node pool so an
# additional pool uses the same patch level and channel as the cluster.
CLUSTER_VERSION_JSON=$(az aro hcp cluster show \
  --name "${CLUSTER_NAME}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --query properties.version \
  --output json)
CLUSTER_CHANNEL_GROUP=$(jq -r '.channelGroup // empty' <<<"${CLUSTER_VERSION_JSON}")

NODEPOOLS_JSON=$(az aro hcp cluster nodepool list \
  --cluster-name "${CLUSTER_NAME}" \
  --resource-group "${CUSTOMER_RG_NAME}" \
  --output json 2>/dev/null || printf '[]')
EXISTING_NODEPOOL_VERSION=$(jq -r '[.[] | select(.name == "workers") | .properties.version.id] | .[0] // empty' <<<"${NODEPOOLS_JSON}")
if [[ -z "${EXISTING_NODEPOOL_VERSION}" ]]; then
  EXISTING_NODEPOOL_VERSION=$(jq -r '[.[] | .properties.version.id] | .[0] // empty' <<<"${NODEPOOLS_JSON}")
fi
EXISTING_NODEPOOL_CHANNEL_GROUP=$(jq -r '[.[] | select(.name == "workers") | .properties.version.channelGroup] | .[0] // empty' <<<"${NODEPOOLS_JSON}")
if [[ -z "${EXISTING_NODEPOOL_CHANNEL_GROUP}" ]]; then
  EXISTING_NODEPOOL_CHANNEL_GROUP=$(jq -r '[.[] | .properties.version.channelGroup] | .[0] // empty' <<<"${NODEPOOLS_JSON}")
fi

MP_OPENSHIFT_VERSION="${MP_OPENSHIFT_VERSION:-${EXISTING_NODEPOOL_VERSION}}"
MP_CHANNEL_GROUP="${MP_CHANNEL_GROUP:-${EXISTING_NODEPOOL_CHANNEL_GROUP:-${CLUSTER_CHANNEL_GROUP:-stable}}}"
: "${MP_OPENSHIFT_VERSION:?No existing node-pool version was found; set MP_OPENSHIFT_VERSION explicitly to an X.Y.Z version}"
echo "Using node pool version ${MP_OPENSHIFT_VERSION} and channel group ${MP_CHANNEL_GROUP}."

duration_to_seconds() {
  local value="$1"
  if [[ "${value}" =~ ^([0-9]+)s$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "${value}" =~ ^([0-9]+)m$ ]]; then
    echo $((BASH_REMATCH[1] * 60))
  elif [[ "${value}" =~ ^([0-9]+)h$ ]]; then
    echo $((BASH_REMATCH[1] * 3600))
  elif [[ "${value}" =~ ^[0-9]+$ ]]; then
    echo "${value}"
  else
    echo "Unsupported duration: ${value}" >&2
    return 1
  fi
}

normalize_zones() {
  tr ', ' '\n' <<<"$1" | awk 'NF && !seen[$0]++' | sort -V
}

discover_availability_zones() {
  local sku_json
  if ! sku_json=$(az vm list-skus \
    --location "${REGION}" \
    --resource-type virtualMachines \
    --size "${MP_MACHINE_TYPE}" \
    --zone \
    --output json); then
    echo "Unable to query VM SKU availability for ${MP_MACHINE_TYPE} in ${REGION}." >&2
    return 1
  fi

  jq -r \
    --arg location "${REGION}" \
    --arg size "${MP_MACHINE_TYPE}" \
    '[.[] | select(.name == $size) | .locationInfo[]? |
      select((.location | ascii_downcase) == ($location | ascii_downcase)) |
      .zones[]?] | unique | .[]' <<<"${sku_json}" | sort -V -u
}

select_availability_zones() {
  local candidates
  local -a candidates_array
  if [[ "${MULTI_AZ:-false}" == "true" ]]; then
    if [[ -n "${MP_ZONES:-}" ]]; then
      candidates=$(normalize_zones "${MP_ZONES}")
      echo "Using configured availability-zone override: $(tr '\n' ' ' <<<"${candidates}")" >&2
    else
      candidates=$(discover_availability_zones)
      echo "Discovered availability zones for ${MP_MACHINE_TYPE} in ${REGION}: $(tr '\n' ' ' <<<"${candidates}")" >&2
    fi

    if [[ -z "${candidates}" ]]; then
      echo "No availability zones are available for ${MP_MACHINE_TYPE} in ${REGION}." >&2
      return 1
    fi
    if [[ ! "${ZONES_COUNT:-}" =~ ^[1-9][0-9]*$ ]]; then
      echo "ZONES_COUNT must be a positive integer when MULTI_AZ=true." >&2
      return 1
    fi
    mapfile -t candidates_array < <(head -n "${ZONES_COUNT}" <<<"${candidates}")
    if (( ${#candidates_array[@]} != ZONES_COUNT )); then
      echo "Requested ${ZONES_COUNT} zones, but only $(wc -l <<<"${candidates}" | xargs) are available." >&2
      return 1
    fi
    printf '%s\n' "${candidates_array[@]}"
    return 0
  fi

  if [[ -n "${MP_ZONE:-}" ]]; then
    printf '%s\n' "${MP_ZONE}"
  else
    printf '\n'
  fi
}

nodepool_name_for_zone() {
  local zone="$1"
  if [[ "${MULTI_AZ:-false}" != "true" ]]; then
    printf '%s\n' "${MP_NAME}"
  else
    printf '%s-az%s\n' "${MP_NAME}" "${zone}"
  fi
}

create_nodepool() {
  local nodepool_name="$1"
  local availability_zone="$2"
  local nodepool_install_start nodepool_rp_ready timeout_seconds deadline state
  local -a nodepool_args

  nodepool_args=(
    --cluster-name "${CLUSTER_NAME}"
    --name "${nodepool_name}"
    --resource-group "${CUSTOMER_RG_NAME}"
    --replicas "${MP_REPLICAS}"
    --vm-size "${MP_MACHINE_TYPE}"
    --version "${MP_OPENSHIFT_VERSION}"
    --channel-group "${MP_CHANNEL_GROUP}"
    --auto-repair "${MP_AUTO_REPAIR}"
    --only-show-errors
  )
  if [[ -n "${MP_LABELS:-}" ]]; then
    nodepool_args+=(--labels "${MP_LABELS}")
  fi
  if [[ -n "${MP_TAINTS:-}" ]]; then
    nodepool_args+=(--taints "${MP_TAINTS}")
  fi
  if [[ -n "${availability_zone}" ]]; then
    nodepool_args+=(--availability-zone "${availability_zone}")
  fi
  if [[ -n "${MP_SUBNET_ID:-}" ]]; then
    nodepool_args+=(--subnet-id "${MP_SUBNET_ID}")
  fi

  echo "Creating ARO HCP node pool ${nodepool_name} on ${CLUSTER_NAME}${availability_zone:+ in availability zone ${availability_zone}}."
  nodepool_install_start=$(date +%s)
  record_nodepool_timer "${nodepool_name}" "install_start" "${nodepool_install_start}"
  az aro hcp cluster nodepool create "${nodepool_args[@]}"

  timeout_seconds=$(duration_to_seconds "${MP_TIMEOUT}")
  deadline=$((SECONDS + timeout_seconds))
  state=""
  while (( SECONDS < deadline )); do
    state=$(az aro hcp cluster nodepool show \
      --cluster-name "${CLUSTER_NAME}" \
      --name "${nodepool_name}" \
      --resource-group "${CUSTOMER_RG_NAME}" \
      --query properties.provisioningState \
      --output tsv 2>/dev/null || true)
    echo "Node pool ${nodepool_name} provisioningState=${state:-NotFound}"
    case "${state}" in
      Succeeded) break ;;
      Failed|Canceled|Cancelled|Error)
        echo "Node pool ${nodepool_name} failed with state ${state}." >&2
        exit 1
        ;;
    esac
    sleep 30
  done

  if [[ "${state}" != "Succeeded" ]]; then
    echo "Timed out waiting for node pool ${nodepool_name}." >&2
    exit 1
  fi

  nodepool_rp_ready=$(date +%s)
  record_nodepool_timer "${nodepool_name}" "rp_ready" "${nodepool_rp_ready}"
  record_nodepool_timer "${nodepool_name}" "install_seconds" "$((nodepool_rp_ready - nodepool_install_start))"

  NODEPOOL_STATE_FILE="${SHARED_DIR}/aro-hcp-nodepool-${nodepool_name}.env"
  cat >"${NODEPOOL_STATE_FILE}" <<EOF
AZURE_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}
CLUSTER_NAME=${CLUSTER_NAME}
CUSTOMER_RG_NAME=${CUSTOMER_RG_NAME}
NODEPOOL_NAME=${nodepool_name}
NODEPOOL_VERSION=${MP_OPENSHIFT_VERSION}
NODEPOOL_VM_SIZE=${MP_MACHINE_TYPE}
NODEPOOL_AVAILABILITY_ZONE=${availability_zone}
NODEPOOL_INSTALL_START=${nodepool_install_start}
NODEPOOL_RP_READY=${nodepool_rp_ready}
NODEPOOL_INSTALL_SECONDS=$((nodepool_rp_ready - nodepool_install_start))
EOF
  chmod 600 "${NODEPOOL_STATE_FILE}"
  echo "ARO HCP node pool ${nodepool_name} is ready."
}

if ! TARGET_ZONE_LIST=$(select_availability_zones); then
  echo "Unable to select availability zones for the additional node pool(s)." >&2
  exit 1
fi
if [[ -n "${TARGET_ZONE_LIST}" ]]; then
  mapfile -t TARGET_ZONES < <(printf '%s\n' "${TARGET_ZONE_LIST}")
else
  TARGET_ZONES=("")
fi

printf '%s\n' "${TARGET_ZONES[@]}" >"${SHARED_DIR}/aro-hcp-nodepool-zones"
printf '%s\n' "$(( ${#TARGET_ZONES[@]} * MP_REPLICAS ))" >"${SHARED_DIR}/aro-hcp-infra-replicas"
for availability_zone in "${TARGET_ZONES[@]}"; do
  nodepool_name=$(nodepool_name_for_zone "${availability_zone}")
  create_nodepool "${nodepool_name}" "${availability_zone}"
done

echo "ARO HCP node pool creation completed for ${#TARGET_ZONES[@]} availability zone(s)."
