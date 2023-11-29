#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

touch "${SHARED_DIR}/filestore_csi_networkconf.txt"
echo "This is for xpn shared vpc testing" >> "${SHARED_DIR}/filestore_csi_networkconf.txt"
