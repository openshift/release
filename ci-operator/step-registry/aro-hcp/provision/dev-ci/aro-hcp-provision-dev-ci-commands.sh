#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
unset GOFLAGS

#-# DEV CI UNPRIVILEGED ENTRYPOINT #-#

# Roll out the non-privileged Microsoft.Azure.ARO.HCP.DevCI.Unprivileged
# entrypoint of the dev-ci topology. This job intentionally runs without a
# Boskos lease: max_concurrency=1 on the postsubmit serializes executions so
# rollouts cannot race each other.
#
# The Owner-only Microsoft.Azure.ARO.HCP.DevCI.Privileged entrypoint (the
# subscription-scoped RBAC grants) is NOT run here; it is applied on demand by
# an OWNERS member because this job's service principal is not a subscription
# Owner.
make -o tooling/templatize/templatize dev-ci-local-run
