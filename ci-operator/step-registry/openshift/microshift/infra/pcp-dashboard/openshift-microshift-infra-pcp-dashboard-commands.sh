#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

EDGE_TOOLING_DIR="${EDGE_TOOLING_DIR:-/opt/app-root/src/edge-tooling}"
PCP_SCRIPTS="${EDGE_TOOLING_DIR}/plugins/microshift-ci/scripts/pcp-graphs"
LOCAL_ARTIFACTS=$(mktemp -d)

# Construct GCS path to the metal-tests step's scenario-info.
# The metal-tests step uploads scenario-info (including pcp-archives.tar) to GCS,
# but these files are no longer on the hypervisor by the time this post step runs.
if [ "${JOB_TYPE}" == "presubmit" ]; then
    GCS_JOB_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
    GCS_JOB_PATH="logs/${JOB_NAME}/${BUILD_ID}"
fi
GCS_BASE="gs://test-platform-results/${GCS_JOB_PATH}"

# Find scenario-info path (wildcard handles different workflow names)
SCENARIO_GCS=$(gsutil ls -d "${GCS_BASE}/artifacts/*/openshift-microshift-e2e-metal-tests/artifacts/scenario-info/" 2>/dev/null | head -1 || true)

if [ -n "${SCENARIO_GCS}" ]; then
    echo "Downloading VM PCP archives from GCS..."
    while IFS= read -r gcs_file; do
        rel="${gcs_file#"${SCENARIO_GCS}"}"
        mkdir -p "${LOCAL_ARTIFACTS}/$(dirname "${rel}")"
        gsutil -q cp "${gcs_file}" "${LOCAL_ARTIFACTS}/${rel}"
    done < <(gsutil ls -r "${SCENARIO_GCS}" 2>/dev/null | grep -E '(pcp-archives\.tar|junit\.xml)$')
else
    echo "WARNING: could not find scenario-info in GCS at ${GCS_BASE}"
fi

# Copy hypervisor PCP logs if available
PMLOGS_DIR=/var/log/pcp/pmlogger
if ssh "${INSTANCE_PREFIX}" "[ -d \"${PMLOGS_DIR}\" ]" ; then
    mkdir -p "${LOCAL_ARTIFACTS}/pmlogs"
    if ! scp -r "${INSTANCE_PREFIX}:${PMLOGS_DIR}/"* "${LOCAL_ARTIFACTS}/pmlogs/" ; then
        echo "WARNING: failed to copy hypervisor pmlogger data, skipping"
    fi
fi

# Generate the interactive PCP dashboard (stored as a regular artifact)
echo "Generating PCP dashboard..."
bash "${PCP_SCRIPTS}/generate-dashboard.sh" \
    --local "${LOCAL_ARTIFACTS}" \
    --output "${ARTIFACT_DIR}/pcp-dashboard.html"

rm -rf "${LOCAL_ARTIFACTS}"

# Build a gcsweb link to the interactive dashboard.
# Spyglass does not execute JavaScript in custom-link HTML, so the toggle
# provides a link to the full interactive dashboard instead.
STEP_NAME="openshift-microshift-infra-pcp-dashboard"
GCSWEB_BASE="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"

WORKFLOW_NAME=""
if [ -n "${SCENARIO_GCS}" ]; then
    WORKFLOW_NAME=$(echo "${SCENARIO_GCS}" | sed -nE 's|.*/artifacts/([^/]+)/openshift-microshift-e2e-metal-tests/.*|\1|p')
fi
if [ -z "${WORKFLOW_NAME}" ]; then
    WORKFLOW_NAME=$(gsutil ls -d "${GCS_BASE}/artifacts/*/" 2>/dev/null | head -1 | sed -nE 's|.*/artifacts/([^/]+)/.*|\1|p' || true)
fi

if [ -n "${WORKFLOW_NAME}" ]; then
    DASHBOARD_URL="${GCSWEB_BASE}/${GCS_JOB_PATH}/artifacts/${WORKFLOW_NAME}/${STEP_NAME}/artifacts/pcp-dashboard.html"
else
    DASHBOARD_URL="${GCSWEB_BASE}/${GCS_JOB_PATH}"
fi

cat > "${ARTIFACT_DIR}/custom-link-pcp.html" <<LINKEOF
<html>
<head>
  <title>PCP Performance Dashboard</title>
  <style>
    body { background-color: #303030; color: #fff; font-family: "Roboto", "Helvetica", "Arial", sans-serif; padding: 16px; margin: 0; }
    a { color: #4fc3f7; font-size: 1.1em; }
    p { color: #bbb; margin-top: 8px; font-size: 0.9em; }
  </style>
</head>
<body>
  <a href="${DASHBOARD_URL}" target="_blank">Open Interactive PCP Performance Dashboard</a>
  <p>Interactive charts require JavaScript, which is not available in Spyglass view.</p>
</body>
</html>
LINKEOF
