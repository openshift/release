#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

payload_url="${RELEASE_IMAGE_LATEST}"

if [[ "${RELEASE_IMAGE_LATEST}" == *"@sha256"* ]]; then
    payload_url=$(echo "${RELEASE_IMAGE_LATEST}" | sed 's/@sha256.*/:latest/')
fi

./check-payload scan payload -V "${MAJOR_MINOR}" --url "${payload_url}"
