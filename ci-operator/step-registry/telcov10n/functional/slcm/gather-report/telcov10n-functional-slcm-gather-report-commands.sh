#!/bin/bash
set -e
set -o pipefail

echo "Gathering report..."
  
GDRIVE_FOLDER_NAME="${JOB_NAME}"
LOCAL_DOWNLOAD_DIR="${ARTIFACT_DIR}"

GDRIVE_PARENT_ID="$(yq '.GDRIVE_FOLDER_ID' /var/reporter/secret)"
GOOGLE_SERVICE_ACCOUNT_KEY="$(yq '.SERVICE_ACCOUNT_KEY' /var/reporter/secret)"
  
export GDRIVE_FOLDER_NAME GDRIVE_PARENT_ID LOCAL_DOWNLOAD_DIR GOOGLE_SERVICE_ACCOUNT_KEY
  
echo "Running script to download report"
python3 scripts/slcm/download_from_gdrive.py
