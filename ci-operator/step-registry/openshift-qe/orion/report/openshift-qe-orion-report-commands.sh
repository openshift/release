#!/bin/bash
set -x
set -euo pipefail

if [ "${RUN_ORION}" == "false" ]; then
  echo "RUN_ORION is false, skipping report."
  exit 0
fi

# Fetch deferred JSON results from previous steps' GCS artifacts
GCS_BUCKET="gs://test-platform-results"
GCS_BASE=""

case "${JOB_TYPE:-}" in
    presubmit)
        if [[ -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" && -n "${PULL_NUMBER:-}" && -n "${JOB_NAME:-}" && -n "${BUILD_ID:-}" ]]; then
            GCS_BASE="${GCS_BUCKET}/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts"
        fi
        ;;
    periodic)
        if [[ -n "${JOB_NAME:-}" && -n "${BUILD_ID:-}" ]]; then
            GCS_BASE="${GCS_BUCKET}/logs/${JOB_NAME}/${BUILD_ID}/artifacts"
        fi
        ;;
esac

if [[ -z "$GCS_BASE" ]]; then
    echo "Could not determine GCS artifacts path. Skipping report."
    exit 0
fi

echo "Fetching deferred orion JSONs from GCS: ${GCS_BASE}"
mkdir -p /tmp/orion-jsons
gsutil -m cp "${GCS_BASE}/*/openshift-qe-orion-*/artifacts/junit_*.json" /tmp/orion-jsons/ 2>/dev/null || true

shopt -s nullglob
json_files=(/tmp/orion-jsons/junit*.json)
shopt -u nullglob

if [ ${#json_files[@]} -eq 0 ]; then
  echo "No deferred orion JSON results found in GCS."
  exit 0
fi

# Copy JSONs to ARTIFACT_DIR for archival
cp "${json_files[@]}" "${ARTIFACT_DIR}/" 2>/dev/null || true

# Set up Python environment and install orion
pushd /tmp
python -m virtualenv ./venv_report
source ./venv_report/bin/activate

if [[ $TAG == "latest" ]]; then
    LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/orion/releases/latest" | jq -r '.tag_name')
else
    LATEST_TAG=$TAG
fi
git clone -q --branch "$LATEST_TAG" "$ORION_REPO" --depth 1
pushd orion
pip install -q -r requirements.txt
pip install -q .
popd && popd

# Build comma-separated file list for orion --report
json_file_list=""
for f in "${json_files[@]}"; do
  json_file_list="${json_file_list:+${json_file_list},}${f}"
done

# Run orion report on all deferred JSONs
# orion --report exits 2 if regressions found, 0 otherwise
set +e
orion --report "$json_file_list" | tee "${ARTIFACT_DIR}/orion-report-summary.txt"
report_exit=$?
set -e

if [ "$report_exit" -eq 2 ]; then
  echo "Orion report detected regressions."
  exit 1
fi

exit "$report_exit"
