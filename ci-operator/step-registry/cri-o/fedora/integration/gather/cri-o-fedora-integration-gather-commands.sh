#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "gathering logs"

#####################################
#####################################

instance_name=$(<"${SHARED_DIR}/gcp-instance-ids.txt")

function getlogs() {
  echo "### Downloading logs..."
  gcloud compute scp --recurse --zone "${ZONE}" --recurse "${instance_name}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT
