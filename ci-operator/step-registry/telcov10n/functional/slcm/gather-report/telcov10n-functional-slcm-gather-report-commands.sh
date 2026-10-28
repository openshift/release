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

echo "Storing cluster-context.xml reports in shared directory"
context_count=0
while IFS= read -r -d '' xml; do
  rel="${xml#"${LOCAL_DOWNLOAD_DIR}/"}"
  if [[ ! "${rel}" =~ (^|/)(junit_[^/]*)/ ]]; then
    continue
  fi
  junit_dir="${BASH_REMATCH[2]}"
  dest="${SHARED_DIR}/${junit_dir}/cluster-context.xml"
  if [[ -e "${dest}" ]]; then
    echo "WARNING: ${dest} already exists, overwriting with ${xml}" >&2
  fi
  mkdir -p "${SHARED_DIR}/${junit_dir}"
  cp "${xml}" "${dest}"
  context_count=$((context_count + 1))
done < <(find "${LOCAL_DOWNLOAD_DIR}" -type f -path '*/junit_*/*' -name 'cluster-context.xml' -print0)

if [[ ${context_count} -eq 0 ]]; then
  echo "WARNING: no cluster-context.xml files found under ${LOCAL_DOWNLOAD_DIR}" >&2
else
  echo "Copied ${context_count} cluster-context.xml file(s) to ${SHARED_DIR}"
fi
