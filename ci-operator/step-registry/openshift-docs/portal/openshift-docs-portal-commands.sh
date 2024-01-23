#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

IFS=' ' read -r -a DISTROS <<< "${DISTROS}"

for DISTRO in "${DISTROS[@]}"; do

    if [ "${DISTRO}" == "openshift-enterprise" ]; then
        TOPICMAP="_topic_maps/_topic_map.yml"
    elif [ "${DISTRO}" == "openshift-rosa" ]; then
        TOPICMAP="_topic_maps/_topic_map_rosa.yml"
    elif [ "${DISTRO}" == "openshift-osd" ]; then
        TOPICMAP="_topic_maps/_topic_map_osd.yml"
    elif [ "${DISTRO}" == "openshift-ms" ]; then
        TOPICMAP="_topic_maps/_topic_map_ms.yml"
    fi

    ./scripts/get-updated-distros.sh | while read -r FILENAME; do
        if [ "${FILENAME}" == "${TOPICMAP}" ]; then
            python3 "${BUILD}" --distro "${DISTRO}" --product "OpenShift Container Platform" --version "${VERSION}" --no-upstream-fetch
        elif [ "${FILENAME}" == "_distro_map.yml" ]; then
            python3 "${BUILD}" --distro "openshift-enterprise" --product "OpenShift Container Platform" --version "${VERSION}" --no-upstream-fetch
        fi
    done
done

if [ -d "drupal-build" ]; then
    python3 makeBuild.py
fi