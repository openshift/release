#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

./scripts/get-updated-distros.sh | while read -r FILENAME; do
    if [ "${FILENAME}" == "_topic_maps/${TOPIC_MAP}" ]; then 
        python3 ${BUILD}.py --distro ${DISTRO} --product ${PRODUCT} --version ${VERSION} --no-upstream-fetch
    else
        echo "No modified AsciiDoc files in ${DISTRO} distro 🥳"
    fi
done

if [ -d "drupal-build" ]; then
    python3 makeBuild.py
fi