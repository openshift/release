#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Enabling the IAM service account of minimal permissions, i.e. no permissions creating/deleting firewall-rules and binding a private zone to the shared VPC in the host project, for deploying OCP cluster into GCP shared VPC..."
cp "${CLUSTER_PROFILE_DIR}/ipi-xpn-no-fw-no-dns-sa.json" "${SHARED_DIR}/xpn_byo-hosted-zone_min_perm_passthrough.json"
