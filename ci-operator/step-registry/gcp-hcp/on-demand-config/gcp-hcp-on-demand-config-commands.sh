#!/usr/bin/env bash
set -euo pipefail

for variable in E2E_TARGET_ENV E2E_TARGET_REGION E2E_TARGET_REGION_PROJECT_ID E2E_TARGET_API_ENDPOINT E2E_TARGET_OIDC_ENDPOINT E2E_TARGET_CUSTOMER_PROJECT_ID; do
  if [[ -z "${!variable:-}" ]]; then
    echo "ERROR: ${variable} must be set for the on-demand HC lifecycle test"
    exit 1
  fi
done

if [[ ! -d "${SHARED_DIR:-}" ]]; then
  echo "ERROR: SHARED_DIR is missing"
  exit 1
fi

for variable in E2E_TARGET_API_ENDPOINT E2E_TARGET_OIDC_ENDPOINT; do
  if [[ "${!variable}" != https://* ]]; then
    echo "ERROR: ${variable} must be an HTTPS URL"
    exit 1
  fi
done

printf '%s\n' "${E2E_TARGET_API_ENDPOINT}" > "${SHARED_DIR}/api-endpoint"
printf '%s\n' "${E2E_TARGET_OIDC_ENDPOINT}" > "${SHARED_DIR}/oidc-endpoint"
printf '%s\n' "${E2E_TARGET_CUSTOMER_PROJECT_ID}" > "${SHARED_DIR}/customer-project-id"
printf '%s\n' "${E2E_TARGET_REGION}" > "${SHARED_DIR}/region"
printf '%s\n' "${E2E_TARGET_REGION_PROJECT_ID}" > "${SHARED_DIR}/region-project-id"

echo "HC lifecycle configuration written for ${E2E_TARGET_ENV}"
