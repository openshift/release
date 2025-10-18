#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

echo "$(date -u --rfc-3339=seconds) - Enabling the IAM service account of minimal permissions for deploying OCP cluster into GCP shared VPC with CCO in Manual mode..."

cp "${CLUSTER_PROFILE_DIR}/ipi-xpn-cco-manual-permissions.json" "${SHARED_DIR}/xpn_min_perm_cco_manual.json"
