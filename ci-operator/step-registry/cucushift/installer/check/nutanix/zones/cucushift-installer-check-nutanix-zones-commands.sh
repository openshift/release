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

if [[ "$SINGLE_ZONE" == "true" ]]; then
    node_zone_list=$(oc get nodes -o=jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io\/zone}')
    echo "Check all nodes running on single zone: $prism_element1"
    for zone in ${node_zone_list}; do
        if [ "$zone" != "$prism_element1" ]; then
            echo "Fail: fail to check single zone: $zone, expected: $prism_element1"
            exit 1
        fi
    done
else
    default_node_pes=$(echo "$prism_element1" "$prism_element2" "$prism_element3" | tr " " "\n" | sort -u | xargs)
    control_plane_pes="$default_node_pes"
    compute_pes="$default_node_pes"
    compute_zone_list=$(oc get nodes -l node-role.kubernetes.io/worker= -o=jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io\/zone}' | tr " " "\n" | sort -u | xargs)
    control_plane_zone_list=$(oc get nodes -l node-role.kubernetes.io/master= -o=jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io\/zone}' | tr " " "\n" | sort -u | xargs)

    if [[ "$CONTROL_PLANE_ZONE" != "" ]]; then
        control_plane_pes=$(echo "$CONTROL_PLANE_ZONE" | sed -e "s/failure-domain-1/$prism_element1/g" -e "s/failure-domain-2/$prism_element2/g" -e "s/failure-domain-3/$prism_element3/g" | tr " " "\n" | sort -u | xargs)
    fi
    if [[ "$COMPUTE_ZONE" != "" ]]; then
        compute_pes=$(echo "$COMPUTE_ZONE" | sed -e "s/failure-domain-1/$prism_element1/g" -e "s/failure-domain-2/$prism_element2/g" -e "s/failure-domain-3/$prism_element3/g" | tr " " "\n" | sort -u | xargs)
    fi
    if [[ $control_plane_zone_list == "$control_plane_pes" ]]; then
        echo "Pass: passed to check control plane zone: $control_plane_zone_list, expected: $control_plane_pes"
    else
        echo "Fail: fail to check control plane zone: $control_plane_zone_list, expected: $control_plane_pes"
        exit 1
    fi
    IFS=" " read -r -a array_compute_pes <<<"$compute_pes"
    IFS=" " read -r -a array_compute_zone_list <<<"$compute_zone_list"
    if [[ "$COMPUTE_REPLICAS" != "" ]] && [[ $COMPUTE_REPLICAS -lt ${#array_compute_pes[@]} ]]; then
        # When compute replicas < zone
        # Check compute zone list number equals compute replicas num
        if [[ ${#array_compute_zone_list[@]} == "$COMPUTE_REPLICAS" ]]; then
            for zone in $compute_zone_list; do
                # shellcheck disable=SC2076
                if ! [[ " $compute_pes " =~ " $zone " ]]; then
                    echo "Fail: fail to check compute zone: $zone, expected: $compute_pes"
                fi
            done
            echo "Pass: passed to check compute zone: $compute_zone_list, expected: $compute_pes"
        else
            echo "Fail: compute nodes should always use different zones when compute replicas less than the number of zones"
            exit 1
        fi
    else
        if [[ "$compute_zone_list" == "$compute_pes" ]]; then
            echo "Pass: passed to check compute zone: $compute_zone_list, expected: $compute_pes"
        else
            echo "Fail: fail to check compute zone: $compute_zone_list, expected: $compute_pes"
            exit 1
        fi
    fi
fi
