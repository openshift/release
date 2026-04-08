#!/bin/bash
set -x
set -euo pipefail

if [ "${RUN_ORION}" == "false" ]; then
  echo "RUN_ORION is false, skipping report."
  exit 0
fi

# Check for deferred JSON results
shopt -s nullglob
json_files=("${SHARED_DIR}"/junit*.json)
shopt -u nullglob

if [ ${#json_files[@]} -eq 0 ]; then
  echo "No deferred orion JSON results found in SHARED_DIR."
  echo "This is expected when RUN_ORION is not set to deferred."
  exit 0
fi

# Copy JSONs to ARTIFACT_DIR for archival
cp "${json_files[@]}" "${ARTIFACT_DIR}/" 2>/dev/null || true

# Set up Python environment and install orion
python --version
pushd /tmp
python -m virtualenv ./venv_report
source ./venv_report/bin/activate

if [[ $TAG == "latest" ]]; then
    LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/orion/releases/latest" | jq -r '.tag_name')
else
    LATEST_TAG=$TAG
fi
git clone --branch "$LATEST_TAG" "$ORION_REPO" --depth 1
pushd orion
pip install -r requirements.txt
pip install .
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
