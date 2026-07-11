#!/bin/bash

# Shared cluster context for UPI libvirt steps. Sourced by conf/install scripts only.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  exit 0
fi

upi_libvirt_cluster_context_init() {
  CLUSTER_SUFFIX="${CLUSTER_SUFFIX:-}"
  CLUSTER_ROLE="${CLUSTER_ROLE:-}"
  LEASE_PATH_PREFIX="${LEASE_PATH_PREFIX:-}"

  if [[ -n "${INFRA_LEASED_RESOURCE:-}" && "${CLUSTER_ROLE}" == "infra" ]]; then
    CLUSTER_LEASE="${INFRA_LEASED_RESOURCE}"
    LEASE_PATH_PREFIX=""
  else
    CLUSTER_LEASE="${LEASED_RESOURCE}"
  fi

  if [[ -n "${CLUSTER_ROLE}" ]]; then
    CLUSTER_WORK_DIR="${SHARED_DIR}/${CLUSTER_ROLE}"
    mkdir -p "${CLUSTER_WORK_DIR}"
    if [[ -z "${CLUSTER_SUFFIX}" ]]; then
      CLUSTER_SUFFIX="-${CLUSTER_ROLE}"
    fi
  else
    CLUSTER_WORK_DIR="${SHARED_DIR}"
  fi

  if [[ "${USE_EXTERNAL_DNS:-false}" == "true" ]]; then
    BASE_DOMAIN="phc-cicd.cis.ibm.net"
    CLUSTER_NAME="${CLUSTER_LEASE}${CLUSTER_SUFFIX}"
  else
    BASE_DOMAIN="${CLUSTER_LEASE}.ci"
    if [[ -n "${CLUSTER_SUFFIX}" ]]; then
      CLUSTER_NAME="${CLUSTER_LEASE}${CLUSTER_SUFFIX}-${UNIQUE_HASH}"
    else
      CLUSTER_NAME="${CLUSTER_LEASE}-${UNIQUE_HASH}"
    fi
  fi

  RESOURCE_PREFIX="${CLUSTER_LEASE}${CLUSTER_SUFFIX}"
  BASE_URL="${CLUSTER_NAME}.${BASE_DOMAIN}"
}

upi_libvirt_cluster_lease_lookup() {
  local key="${1}"
  if [[ -n "${LEASE_PATH_PREFIX}" ]]; then
    key="${LEASE_PATH_PREFIX}${key}"
  fi
  local lookup
  lookup=$(yq-v4 -oy ".\"${CLUSTER_LEASE}\".${key}" "${LEASE_CONF}")
  if [[ -z "${lookup}" ]]; then
    echo "Couldn't find ${key} in lease config for ${CLUSTER_LEASE}"
    exit 1
  fi
  echo "$lookup"
}
