#!/bin/bash -eu
set -o pipefail

if [ -z "${SHARED_DIR}" ]; then
  echo "[ERROR] SHARED_DIR is not set. This script must run in Prow CI environment."
  exit 1
fi

if [ ! -f "${SHARED_DIR}/az-resource-group" ]; then
  echo "[ERROR] az-resource-group was not placed in SHARED_DIR"
  exit 1
fi

rpm --import https://packages.microsoft.com/keys/microsoft.asc
dnf install -y https://packages.microsoft.com/config/rhel/9.0/packages-microsoft-prod.rpm
dnf install -y azure-cli

az_resource_group=$(cat "${SHARED_DIR}/az-resource-group")
echo "[INFO] Delete Kind VM resource group $az_resource_group"
az group delete --name "$az_resource_group" --yes
echo "[SUCCESS] Deleted Kind VM resource group $az_resource_group"
