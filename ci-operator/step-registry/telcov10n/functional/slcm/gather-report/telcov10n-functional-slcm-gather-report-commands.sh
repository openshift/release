#!/bin/bash
set -e
set -o pipefail

echo "Gathering report..."
  
GDRIVE_FOLDER_NAME="${JOB_NAME}"
GDRIVE_PARENT_ID="$(cat /var/reporter/GDRIVE_FOLDER_ID)"
LOCAL_DOWNLOAD_DIR="${ARTIFACT_DIR}/junit_reports"
GOOGLE_SERVICE_ACCOUNT_KEY=$(cat /var/reporter/SERVICE_ACCOUNT_KEY | sed "s/^'//; s/'$//")
  
export GDRIVE_FOLDER_NAME GDRIVE_PARENT_ID LOCAL_DOWNLOAD_DIR GOOGLE_SERVICE_ACCOUNT_KEY
  
echo "Running script to download report"
python3 scripts/slcm/download_from_gdrive.py
