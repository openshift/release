#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

./scripts/get-updated-distros.sh | while read -r filename; do
    if [ "$filename" == "_topic_maps/_topic_map.yml" ]; then python3 ${BUILD}.py --distro openshift-enterprise --product "OpenShift Container Platform" --version 4.15 --no-upstream-fetch

    elif [ "$filename" == "_topic_maps/_topic_map_osd.yml" ]; then python3 ${BUILD}.py --distro openshift-dedicated --product "OpenShift Dedicated" --version 4 --no-upstream-fetch

    elif [ "$filename" == "_topic_maps/_topic_map_ms.yml" ]; then python3 ${BUILD}.py --distro microshift --product "Microshift" --version 4 --no-upstream-fetch

    elif [ "$filename" == "_topic_maps/_topic_map_rosa.yml" ]; then python3 ${BUILD}.py --distro openshift-rosa --product "Red Hat OpenShift Service on AWS" --version 4 --no-upstream-fetch

    elif [ "$filename" == "_distro_map.yml" ]; then python3 ${BUILD}.py --distro openshift-enterprise --product "OpenShift Container Platform" --version 4.15 --no-upstream-fetch
    fi
    done

if [ -d "drupal-build" ]; then python3 makeBuild.py; fi
