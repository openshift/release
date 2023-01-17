#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

readonly OADP_GIT_URL="https://github.com/CSPI-QE/oadp-e2e-qe"
readonly OADP_GIT_DIR="${HOME}/cspi"
mkdir -p "${OADP_GIT_DIR}"

ls -laht /usr/local/

df -h

echo "lsblk"

lsblk

# git clone --no-checkout "${OADP_GIT_URL}" "${OADP_GIT_DIR}"

#Create the AWS S3 Storage Bucket



echo "finished"