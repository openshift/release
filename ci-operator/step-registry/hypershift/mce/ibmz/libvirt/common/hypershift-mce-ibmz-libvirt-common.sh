#!/bin/bash

# Shared helpers for dual-cluster libvirt UPI installs (mgmt + infra).

cluster_libvirt_init() {
  CLUSTER_ROLE="${CLUSTER_ROLE:-mgmt}"
  CLUSTER_SUFFIX="${CLUSTER_SUFFIX:--${CLUSTER_ROLE}}"
  CLUSTER_LEASE="${LEASED_RESOURCE}"
  if [[ "${CLUSTER_ROLE}" == "infra" && -n "${INFRA_LEASED_RESOURCE:-}" ]]; then
    CLUSTER_LEASE="${INFRA_LEASED_RESOURCE}"
    LEASE_PATH_PREFIX=""
  fi
  CLUSTER_DIR="${SHARED_DIR}/${CLUSTER_ROLE}"
  mkdir -p "${CLUSTER_DIR}"

  if [[ "${USE_EXTERNAL_DNS:-false}" == "true" ]]; then
    BASE_DOMAIN="phc-cicd.cis.ibm.net"
    CLUSTER_NAME="${CLUSTER_LEASE}${CLUSTER_SUFFIX}"
  else
    BASE_DOMAIN="${CLUSTER_LEASE}.ci"
    CLUSTER_NAME="${CLUSTER_LEASE}${CLUSTER_SUFFIX}-${UNIQUE_HASH}"
  fi
  RESOURCE_PREFIX="${CLUSTER_LEASE}${CLUSTER_SUFFIX}"
  LEASE_PATH_PREFIX="${LEASE_PATH_PREFIX:-}"
}

cluster_libvirt_lease_lookup() {
  local key
  if [[ -n "${LEASE_PATH_PREFIX}" ]]; then
    key="${LEASE_PATH_PREFIX}${1}"
  else
    key="${1}"
  fi
  local lookup
  lookup=$(yq-v4 -oy ".\"${CLUSTER_LEASE}\".${key}" "${LEASE_CONF}")
  if [[ -z "${lookup}" ]]; then
    echo "Couldn't find ${key} in lease config for ${CLUSTER_LEASE}"
    exit 1
  fi
  echo "$lookup"
}

cluster_libvirt_save_credentials() {
  local install_dir="${1}"
  echo "Saving authentication files for ${CLUSTER_ROLE} cluster..."
  if [[ -f "${install_dir}/metadata.json" ]]; then
    cp "${install_dir}/metadata.json" "${CLUSTER_DIR}/"
  fi
  cp "${install_dir}/auth/kubeconfig" "${CLUSTER_DIR}/kubeconfig"
  cp "${install_dir}/auth/kubeadmin-password" "${CLUSTER_DIR}/kubeadmin-password"
  echo "${CLUSTER_NAME}" > "${SHARED_DIR}/${CLUSTER_ROLE}_cluster_name"
  if [[ "${CLUSTER_ROLE}" == "mgmt" ]]; then
    cp "${install_dir}/auth/kubeconfig" "${SHARED_DIR}/kubeconfig"
    cp "${install_dir}/auth/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"
  fi
}
