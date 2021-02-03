#!/bin/bash -x

set -o nounset
set -o errexit
set -o pipefail

echo "Backup loki index and chunks ..."
mkdir -p "${ARTIFACT_DIR}/loki-container-logs"
oc --insecure-skip-tls-verify exec -n loki loki-0 -- tar cvzf - -C /data . > "${ARTIFACT_DIR}/loki-container-logs/loki-data.tar.gz"