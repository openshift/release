#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

./scripts/get-updated-distros.sh | while read -r filename; do
    if [ "$filename" == "_topic_maps/_topic_map.yml" ]; then python3 "${BUILD}" --distro openshift-enterprise --product "OpenShift Container Platform" --version "${VERSION}" --no-upstream-fetch

    elif [ "$filename" == "_topic_maps/_topic_map_osd.yml" ]; then python3 "${BUILD}" --distro openshift-dedicated --product "OpenShift Dedicated" --version "${VERSION}" --no-upstream-fetch

    elif [ "$filename" == "_topic_maps/_topic_map_ms.yml" ]; then python3 "${BUILD}" --distro microshift --product "Microshift" --version "${VERSION}" --no-upstream-fetch

    elif [ "$filename" == "_topic_maps/_topic_map_rosa.yml" ]; then python3 "${BUILD}" --distro openshift-rosa --product "Red Hat OpenShift Service on AWS" --version "${VERSION}" --no-upstream-fetch

    elif [ "$filename" == "_distro_map.yml" ]; then python3 "${BUILD}" --distro openshift-enterprise --product "OpenShift Container Platform" --version "${VERSION}" --no-upstream-fetch
    else
        echo "No modified AsciiDoc files in distro 🥳"
    fi
done

if [ -d "drupal-build" ]; then
    python3 makeBuild.py
fi