#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

TARGET_DIR="${SHARED_DIR}"
PROVIDER=ibmcloud

oc adm release extract --credentials-requests=true --cloud="${PROVIDER}" --to="${TARGET_DIR}" "${RELEASE_IMAGE_LATEST}"
