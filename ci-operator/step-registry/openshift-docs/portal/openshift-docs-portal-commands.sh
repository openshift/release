#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

curl https://raw.githubusercontent.com/openshift/openshift-docs/main/scripts/get-updated-distros.sh > scripts/get-updated-distros.sh
curl https://raw.githubusercontent.com/openshift/openshift-docs/main/build_for_portal.py > build_for_portal.py
curl https://raw.githubusercontent.com/openshift/openshift-docs/main/makeBuild.py > makeBuild.py

IFS=' ' read -r -a DISTROS <<< "${DISTROS}"

# Set the default value
TOPICMAP="_topic_maps/_topic_map.yml"

for DISTRO in "${DISTROS[@]}"; do
    # Only override for distros that need a different value
    case "${DISTRO}" in
        "openshift-rosa")
            TOPICMAP="_topic_maps/_topic_map_rosa.yml"
            ;;
        "openshift-rosa-hcp")
            TOPICMAP="_topic_maps/_topic_map_rosa_hcp.yml"
            ;;
        "openshift-dedicated")
            TOPICMAP="_topic_maps/_topic_map_osd.yml"
            ;;
        "microshift")
            TOPICMAP="_topic_maps/_topic_map_ms.yml"
            ;;
    esac

    ./scripts/get-updated-distros.sh | while read -r FILENAME; do
        if [ "${FILENAME}" == "${TOPICMAP}" ]; then
            echo -e "\e[91mBuilding openshift-docs with ${DISTRO} distro...\e[0m"
            python3 "${BUILD}" --distro "${DISTRO}" --product "OpenShift Container Platform" --version "${VERSION}" --no-upstream-fetch
        elif [ "${FILENAME}" == "_distro_map.yml" ]; then
            python3 "${BUILD}" --distro "openshift-enterprise" --product "OpenShift Container Platform" --version "${VERSION}" --no-upstream-fetch
        fi
    done
done

if [ -d "drupal-build" ]; then
    python3 makeBuild.py
fi