#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh

declare prism_element1
declare prism_element2
declare prism_element3

# shellcheck source=/dev/null
source "${NUTANIX_AUTH_PATH}"

node_zone_list=$(oc get nodes -o=jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io\/zone}')

if [[ "$SINGLE_ZONE" == "true" ]]; then
    echo "Check all nodes running on single zone: $prism_element1"
    for zone in ${node_zone_list}; do
        if [ "$zone" != "$prism_element1" ]; then
            echo "Fail: fail to check single zone: $zone, expected: $prism_element1"
            exit 1
        fi
    done
else
    echo "Check node running on multy zone: $prism_element1"
    # shellcheck disable=SC2076
    if ! [[ " ${node_zone_list[*]} " =~ " $prism_element1 " ]]; then
        echo "Fail: fail to check zone: $prism_element1 exist"
        exit 1
    fi
    echo "Check node running on multy zone: $prism_element2"
    # shellcheck disable=SC2076
    if ! [[ " ${node_zone_list[*]} " =~ " $prism_element2 " ]]; then
        echo "Fail: fail to check zone: $prism_element2 exist"
        exit 1
    fi
    echo "Check node running on multy zone: $prism_element3"
    # shellcheck disable=SC2076
    if ! [[ " ${node_zone_list[*]} " =~ " $prism_element3 " ]]; then
        echo "Fail: fail to check zone: $prism_element3 exist"
        exit 1
    fi
fi
