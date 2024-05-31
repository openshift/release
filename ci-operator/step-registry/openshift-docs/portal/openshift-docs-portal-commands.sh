#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

curl https://raw.githubusercontent.com/openshift/openshift-docs/main/scripts/get-updated-distros.sh > scripts/get-updated-distros.sh

LOG=$(mktemp)

check_errors() {
    if grep -q 'asciidoctor: ERROR' "$1"; then
        cat "${LOG}"
        echo -e "\e[91mAsciidoctor error found. Exiting...\e[0m"
        exit 1
    fi
}

IFS=' ' read -r -a DISTROS <<< "${DISTROS}"

for DISTRO in "${DISTROS[@]}"; do

    case "${DISTRO}" in
        "openshift-enterprise"|"openshift-acs"|"openshift-pipelines"|"openshift-serverless"|"openshift-gitops"|"openshift-builds"|"openshift-service-mesh"|"openshift-opp"|"openshift-rhde")
            TOPICMAP="_topic_maps/_topic_map.yml"
            ;;
        "openshift-rosa")
            TOPICMAP="_topic_maps/_topic_map_rosa.yml"
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
            python3 "${BUILD}" --distro "${DISTRO}" --product "OpenShift Container Platform" --version "${VERSION}" --no-upstream-fetch >> "${LOG}" 2>&1
        elif [ "${FILENAME}" == "_distro_map.yml" ]; then
            python3 "${BUILD}" --distro "openshift-enterprise" --product "OpenShift Container Platform" --version "${VERSION}" --no-upstream-fetch >> "${LOG}" 2>&1
        fi
    done
done

if [ -d "drupal-build" ]; then
    python3 makeBuild.py >> "${LOG}" 2>&1
fi

check_errors "${LOG}"
