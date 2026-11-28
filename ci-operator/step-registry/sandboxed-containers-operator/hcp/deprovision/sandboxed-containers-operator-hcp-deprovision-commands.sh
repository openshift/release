#!/bin/bash

set -euo pipefail
# No -x: the sourced environment carries AWS credentials and pull secret
# paths; command tracing would leak them into the CI log.

echo "=========================================="
echo "OSC HCP :: deprovision (hosted + management cluster)"
echo "=========================================="

HCP_ENV="${SHARED_DIR}/hcp/env.sh"
if [[ ! -f "${HCP_ENV}" ]]; then
    if [[ -d "${SHARED_DIR}/hcp/work" ]]; then
        # Provision ran but its state is incomplete - do not silently skip
        # teardown or the AWS resources will leak.
        echo "ERROR: ${SHARED_DIR}/hcp/work exists but ${HCP_ENV} is missing"
        echo "Refusing to skip teardown with clusters potentially deployed"
        exit 1
    fi
    echo "${HCP_ENV} not found - the provision step never ran, nothing to tear down"
    exit 0
fi
# shellcheck disable=SC1090
source "${HCP_ENV}"

HCP_SCRIPT="hack/hcp/bin/hypershift-cluster-setup"
if [[ ! -f "${HCP_SCRIPT}" ]]; then
    echo "ERROR: ${HCP_SCRIPT} not found in the source checkout"
    exit 1
fi
[[ -x "${HCP_SCRIPT}" ]] || chmod +x "${HCP_SCRIPT}"
HCP_SCRIPT="$(pwd)/${HCP_SCRIPT}"

command -v openshift-install >/dev/null 2>&1 || { echo "ERROR: openshift-install not found in the step image"; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws not found in the step image"; exit 1; }

# Delete the hosted cluster first (HostedCluster, NodePool, OIDC S3 bucket,
# ccoctl-created IAM roles), then the management cluster
# (openshift-install destroy cluster). --prow reads the shared state and
# cluster names; --yes is implied but kept for explicitness.
"${HCP_SCRIPT}" --prow --yes hosted teardown
"${HCP_SCRIPT}" --prow --yes management teardown

echo "HCP deprovision complete"
