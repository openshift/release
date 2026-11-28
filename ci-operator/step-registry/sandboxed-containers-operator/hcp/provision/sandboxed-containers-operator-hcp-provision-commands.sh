#!/bin/bash

set -euo pipefail
# No -x: the sourced environment carries AWS credentials and pull secret
# paths; command tracing would leak them into the CI log.

echo "=========================================="
echo "OSC HCP :: provision (management + hosted cluster)"
echo "=========================================="

HCP_ENV="${SHARED_DIR}/hcp/env.sh"
if [[ ! -f "${HCP_ENV}" ]]; then
    echo "ERROR: ${HCP_ENV} not found - the hcp-conf-aws step did not run"
    exit 1
fi
# shellcheck disable=SC1090
source "${HCP_ENV}"

# The script ships in the repository under test (hack/hcp); a from:src step
# runs with the checkout as the working directory.
HCP_SCRIPT="hack/hcp/bin/hypershift-cluster-setup"
if [[ ! -f "${HCP_SCRIPT}" ]]; then
    echo "ERROR: ${HCP_SCRIPT} not found in the source checkout"
    echo "       (it lives under hack/hcp of openshift/sandboxed-containers-operator)"
    exit 1
fi
[[ -x "${HCP_SCRIPT}" ]] || chmod +x "${HCP_SCRIPT}"
HCP_SCRIPT="$(pwd)/${HCP_SCRIPT}"

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found in the step image"; exit 1; }

# --prow: non-interactive, state under ${SHARED_DIR}, per-job cluster names
# from PROW_JOB_ID, cluster-profile credentials; --yes is implied but kept
# for explicitness. The script dispatches on HCP_CLOUD internally, so this
# step stays cloud-agnostic.
"${HCP_SCRIPT}" --prow --yes management create
"${HCP_SCRIPT}" --prow --yes management setup
"${HCP_SCRIPT}" --prow --yes hosted setup
"${HCP_SCRIPT}" --prow --yes hosted validate

# Point the standard CI kubeconfig at the hosted (managed) cluster under test
# so the shared OSC chains run against the work plane. Names and paths come
# from the script's published state - never re-derived here.
# shellcheck disable=SC1090
source "${SHARED_DIR}/hcp/state.sh"
cp "${HCP_HOSTED_KUBECONFIG}" "${SHARED_DIR}/kubeconfig"
echo "${HCP_HOSTED_CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

echo "HCP provision complete: mgmt=${HCP_MGMT_CLUSTER_NAME} hosted=${HCP_HOSTED_CLUSTER_NAME}"
