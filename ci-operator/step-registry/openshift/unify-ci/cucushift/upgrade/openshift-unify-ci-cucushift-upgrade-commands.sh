#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi

TO_VERSION="${RELEASE_IMAGE_LATEST}"
# TO_VERSION="4.7.24"
# CHANNEL="stable"
# FORCE="true"

step=20 # second

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export OPENSHIFT_ENV_OCP4_ADMIN_CREDS_SPEC=${KUBECONFIG}
export KUBECONFIG=${KUBECONFIG}

# Update channel if needed
current_channel=$(oc get clusterversion -o json|jq ".items[0].spec.channel")
echo "current channel is: $current_channel"
IFS='.' read -r -a arr <<<"$TO_VERSION"
target_channel="$(echo "$CHANNEL-${arr[0]}.${arr[1]}")"
if [ "$current_channel" != "$target_channel" ]
then
    echo "Target channel is $target_channel, prepare update channel..."

    oc patch clusterversion/version --patch '{"spec": {"channel": "'$target_channel'"}}' --type merge
    oc patch clusterversion/version --patch '{"spec":{"upstream":"https://amd64.ocp.releases.ci.openshift.org/graph"}}' --type=merge

    current_channel=$(oc get clusterversion -o json|jq ".items[0].spec.channel")
    echo "New channel is: $current_channel"
fi

# TODO： Upgrade for disconnected cluster

echo "Upgrade OCP to $TO_VERSION"
script="oc adm upgrade --to=$TO_VERSION"
if [[ "$TO_VERSION" == *x86_64* ]]
then
    script="oc adm upgrade --to-image=quay.io/openshift-release-dev/ocp-release:$TO_VERSION"
fi

if [[ "$TO_VERSION" == *nightly* || "$TO_VERSION" == *ci* ]]
then
    script="oc adm upgrade --to-image=registry.ci.openshift.org/ocp/release:$TO_VERSION"
fi

if [[ ${FORCE} == "true" ]]
then
    script+=" --force=true --allow-explicit-upgrade=true --allow-upgrade-with-warnings=true"
fi

echo "$script"

echo "OCP is upgrading..."
$script


# Waiting 2 hours for OCP upgraded to target version
for i in $(seq 1 360);
do
    IFS=$'\n'
    echo "---------------$i--------------"
    # echo "check if cluster operator availiable/degraded............."
    # clusteroperators=$(oc get clusteroperators)
    # 
    # for var in ${clusteroperators[@]}
    # do
    #     # Example:
    #     # NAME                                       VERSION                             AVAILABLE   PROGRESSING   DEGRADED   SINCE
    #     # authentication                             4.7.0-0.nightly-2021-08-06-180629   True        False         False      43m
    #     # baremetal                                  4.7.0-0.nightly-2021-08-06-180629   True        False         False      63m
    #     operator=$(echo $var|awk '{print $1}')
    #     is_availiable=$(echo $var|awk '{print $3}')
    #     is_degraded=$(echo $var|awk '{print $5}')
    #     if [[ is_availiable == "False" || $is_degraded == 'True' ]]
    #     then
    #         echo "NAME              VERSION       AVAILABLE   PROGRESSING   DEGRADED   SINCE"
    #         echo $var
    #         exit 1
    #     fi
    # done

    echo "check OCP version............."
    version_json=$(oc get clusterversion -o json)
    version=$( echo $version_json|jq ".items[0].status.history[0].version" )
    version=$(echo ${version#\"})
    version=$(echo ${version%\"})
    state=$( echo $version_json|jq ".items[0].status.history[0].state" )
    # There should be an error when OCP upgraded from more than 2 versions
    if [[ "$version" != "$TO_VERSION" || "$state" != "\"Completed\"" ]]
    then
        echo "OCP updating is not finished, current version is: $version, state is $state"
        sleep $step
        continue
    fi

    echo "Wait all nodes ready............."
    str_nodes=$(oc get nodes)
    for var in "${str_nodes[@]}"
    do
        # Example:
        # NAME                                        STATUS   ROLES    AGE   VERSION
        # ip-10-0-140-44.us-east-2.compute.internal   Ready    worker   12h   v1.20.0+558d959
        # ip-10-0-150-59.us-east-2.compute.internal   Ready    master   12h   v1.20.0+558d959
        for item in "${var[@]}"
        do
            node=$(echo $item|awk '{print $1}')
            status=$(echo $item|awk '{print $2}')
            if [[ $status != 'Ready' && $status != 'STATUS' ]]
            then
                echo "Node [$node] is not ready: $status"
                sleep $step
                continue
            fi
        done
    done

    echo "$str_nodes"

    echo "Wait all mcp ready............."
    str_mcp=$(oc get mcp)
    for var in "${str_mcp[@]}"
    do
        # Example:
        # NAME     CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
        # master   rendered-master-092473c2a029f74d51adab6ea3384b53   True      False      False      3              3                   3                     0                      12h
        # worker   rendered-worker-29ff2da152f7fd375b64703b13f3979e   True      False      False      3              3                   3                     0                      12h   
        for item in "${var[@]}"
        do
            mcp=$(echo $item|awk '{print $1}')
            updated=$(echo $item|awk '{print $3}')

            if [[ $updated != 'True' && $updated != 'UPDATED' ]]
            then
                echo "MCP [$mcp] is not ready: $updated"
                sleep $step
                continue
            fi
        done
    done

    echo "$str_mcp"

    echo "OCP upgraded successfully"
    exit 0
done

echo "After waiting 2 hours, OCP still not updated"
exit 1