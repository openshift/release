#!/bin/bash
set -e
set -o pipefail

echo "Gathering report..."
  
GDRIVE_FOLDER_NAME="${JOB_NAME}"
GDRIVE_PARENT_ID="$(cat /var/reporter/GDRIVE_FOLDER_ID)"
LOCAL_DOWNLOAD_DIR="${ARTIFACT_DIR}"
GOOGLE_SERVICE_ACCOUNT_KEY=$(cat /var/reporter/SERVICE_ACCOUNT_KEY | sed "s/^'//; s/'$//")
  
export GDRIVE_FOLDER_NAME GDRIVE_PARENT_ID LOCAL_DOWNLOAD_DIR GOOGLE_SERVICE_ACCOUNT_KEY
  
echo "Running script to download report"
python3 scripts/slcm/download_from_gdrive.py

echo "Storing JUnit reports in shared directory"
junit_count=0
while IFS= read -r -d '' xml; do
  dest="${SHARED_DIR}/$(basename "${xml}")"
  if [[ -e "${dest}" ]]; then
    echo "WARNING: ${dest} already exists, overwriting with ${xml}" >&2
  fi
  cp "${xml}" "${dest}"
  junit_count=$((junit_count + 1))
done < <(find "${LOCAL_DOWNLOAD_DIR}" -path '*/junit_*/*.xml' -print0)

if [[ ${junit_count} -eq 0 ]]; then
  echo "WARNING: no JUnit XML files found under ${LOCAL_DOWNLOAD_DIR}/junit_*/" >&2
else
  echo "Copied ${junit_count} JUnit XML file(s) to ${SHARED_DIR}"
fi
