#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/env"
chmod +x ${SHARED_DIR}/login_script.sh
${SHARED_DIR}/login_script.sh

instance_name=$(<"${SHARED_DIR}/gcp-instance-ids.txt")

timeout --kill-after 10m 400m gcloud compute ssh --zone="${ZONE}" ${instance_name} -- bash - << EOF 
    sudo chown -R deadbeef /tmp/*
    sudo chmod -R 777 /tmp/artifacts/*
EOF


function getlogs() {
  echo "### Downloading logs..."
  gcloud compute scp --recurse --zone "${ZONE}" --recurse "${instance_name}:/tmp/artifacts/*" "${ARTIFACT_DIR}"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT
