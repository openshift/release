#!/bin/bash

set -euo pipefail

if [ -z "${CLUSTER_NAME:-}" ]; then
  CLUSTER_NAME="$(echo -n "$PROW_JOB_ID"|sha256sum|cut -c-20)"
fi
echo "$(date) Deleting HyperShift cluster ${CLUSTER_NAME}"
bin/hypershift destroy cluster openstack \
  --name "${CLUSTER_NAME}" \
  --cluster-grace-period 40m
echo "$(date) Finished deleting cluster"
