#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


if [ "${MCO_CONF_DAY2_PINTARGETRELEASE,,}" == "false" ] || [ "${MCO_CONF_DAY2_PINTARGETRELEASE}" == "" ]; then
    echo "Step skipped!"
    exit 0
fi


if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    echo "Setup proxy"
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Currently the PinnedImageSet feature is only available through TechPreviewNoUpgrade featureset.
# Remove this check once the PinnedImageSet feature becomes GA
if [ "$(oc get featuregate cluster -ojsonpath='{.spec.featureSet}')" != "TechPreviewNoUpgrade" ]; then
    echo "This step can only be executed in clusters with TechPreviewUpgrade featureset"
    exit 255
fi

# If it's serial upgrades then override-upgrade file will store the release and overrides OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE
# upgrade-edge file expects a comma separated releases list like target_release1,target_release2,...
# If those file exists we fail the execution since serial upgrades are not supported in this step
if [[ -f "${SHARED_DIR}/upgrade-edge" ]]; then
    echo "ERROR: Serial upgrades are not supported!!"
    exit 255
fi


TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
DIGEST=$(oc adm release info "${TARGET}" -a "${CLUSTER_PROFILE_DIR}"/pull-secret -o json | jq -r .digest)
REPO="${TARGET%:*}"
REPO="${REPO%@sha256*}"
TARGET_DIGEST="${REPO}@${DIGEST}"

JUNIT_SUITE="PinnedImageSet"
JUNIT_TEST="Pin target release image"

function create_failed_junit() {
  local SUITE_NAME=$1
  local TEST_NAME=$2
  local FAILURE_MESSAGE=$3

  cat >"${ARTIFACT_DIR}/junit_pintargetrelease.xml" <<EOF
<testsuite name="$SUITE_NAME" tests="1" failures="1">
  <testcase name="$TEST_NAME">
    <failure message="">$FAILURE_MESSAGE
    </failure>
  </testcase>
</testsuite>
EOF
}

function create_passed_junit() {
  local SUITE_NAME=$1
  local TEST_NAME=$2

  cat >"${ARTIFACT_DIR}/junit_pintargetrelease.xml" <<EOF
<testsuite name="$SUITE_NAME" tests="1" failures="0">
  <testcase name="$TEST_NAME"/>
</testsuite>
EOF
}

function debug() {
    MCP="${1}"

    echo "-------------------"
    oc get mcp -o yaml "${MCP}"
    echo "-------------------"
    oc get pinnedimageset -o yaml "99-${MCP}-pinned-release"
    echo "-------------------"
    for node in $(oc get nodes -l node-role.kubernetes.io/"${MCP}" -o name)
    do
       n=${node/node\//}
       echo "$n"
       oc get machineconfignode "$n" -ojsonpath='{.status.conditions[?(@.type=="PinnedImageSetsDegraded")]}' | jq
       oc get machineconfignode "$n" -ojsonpath='{.status.conditions[?(@.type=="PinnedImageSetsProgressing")]}' | jq
    done
    echo "-------------------"
}

function wait_for_mcp_to_start_pinning_images() {
    MCP="${1}"
    TIME=10
    TOTAL=0
    TIME_OUT=180

    echo "Waiting for MCP ${MCP} to start pinning the images"

    while [ "$(oc get mcp "${MCP}" -ojsonpath='{.status.poolSynchronizersStatus[?(@.poolSynchronizerType=="PinnedImageSets")].updatedMachineCount}')"  == \
        "$(oc get mcp "${MCP}" -ojsonpath='{.status.machineCount}')" ]; do

        TOTAL=$((TIME + TOTAL))

        if (( TOTAL > TIME_OUT  )); then
            echo "MCP ${MCP} is taking to long to start pinning images"
            # Print debug info
            debug "${MCP}"
            create_failed_junit "$JUNIT_SUITE" "$JUNIT_TEST" "$MCP has not started pinning the target release image"
            exit 255
        fi

        echo "Waiting ${TIME} seconds..."
        sleep $TIME
    done

    echo "Pool $MCP has started to pin the images"
}

function wait_for_mcp_to_finish_pinning_images() {
    MCP="${1}"
    TIME=180
    TOTAL=0
    TIME_OUT=3000

    echo "Waiting for MCP ${MCP} to finish"

    while [ "$(oc get mcp "${MCP}" -ojsonpath='{.status.poolSynchronizersStatus[?(@.poolSynchronizerType=="PinnedImageSets")].updatedMachineCount}')"  != \
        "$(oc get mcp "${MCP}" -ojsonpath='{.status.machineCount}')" ]; do

        TOTAL=$((TIME + TOTAL))

        if (( TOTAL > TIME_OUT )); then
            echo "MCP ${MCP} is taking to long to pin the images"
            # Print debug info
            debug "${MCP}"
            create_failed_junit "$JUNIT_SUITE" "$JUNIT_TEST" "$MCP cannot pin the target release image"
            exit 255
        fi

        echo "Waiting ${TIME} seconds..."
        sleep $TIME
    done

    echo "Pool $MCP has finished"
}


function get_pinned_image_file() {
    MCP="${1}"
    echo "${ARTIFACT_DIR}/pinnedimageset-${MCP}.yaml"
}

# Writing the PinnedImageSet files
for MACHINE_CONFIG_POOL in ${MCO_CONF_DAY2_PINTARGETRELEASE_MCPS}; do
    file=$(get_pinned_image_file "${MACHINE_CONFIG_POOL}")
    echo "Rendering PinnedImageSet for pool ${MACHINE_CONFIG_POOL}"


    cat << EOF >> "${file}"
apiVersion: machineconfiguration.openshift.io/v1alpha1
kind: PinnedImageSet
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${MACHINE_CONFIG_POOL}
  name: 99-${MACHINE_CONFIG_POOL}-pinned-release
spec:
  pinnedImages:
$(oc adm release info "${TARGET}" -a "${CLUSTER_PROFILE_DIR}"/pull-secret -o pullspec | awk '{print "   - name: " $1}')
EOF

    # Add the release image itself as well
    echo "   - name: $TARGET_DIGEST" >> "${file}"

done

# Creating the PinnedImageSet resources
for MACHINE_CONFIG_POOL in ${MCO_CONF_DAY2_PINTARGETRELEASE_MCPS}; do
    file=$(get_pinned_image_file "${MACHINE_CONFIG_POOL}")
    echo "Creating PinnedImageSet for pool ${MACHINE_CONFIG_POOL}"
    oc create -f "${file}"

    wait_for_mcp_to_start_pinning_images "${MACHINE_CONFIG_POOL}"
done

# Waiting for the pools to pin the images
for MACHINE_CONFIG_POOL in ${MCO_CONF_DAY2_PINTARGETRELEASE_MCPS}; do
    wait_for_mcp_to_finish_pinning_images "${MACHINE_CONFIG_POOL}"
done

if [ "${MCO_CONF_DAY2_PINTARGETRELEASE_REMOVE_PULLSECRET,,}" == "true" ]; then
    echo "Configure pull-secret to be empty!"
    if oc get secret pull-secret -n openshift-config; then
        oc set data secret/pull-secret -n openshift-config .dockerconfigjson={}

        # Wait for MCP to start updating
        oc wait mcp master --for='condition=UPDATING=True' --timeout=300s

        # Wait for MCP to apply the new configuration
        oc wait mcp master --for='condition=UPDATED=True' --timeout=600s
        oc wait mcp worker --for='condition=UPDATED=True' --timeout=600s
    else
        echo "ERROR! Global cluster pull secret does not exist."
        create_failed_junit "$JUNIT_SUITE" "$JUNIT_TEST" "The cluster has no pull-secret"
        exit 255
    fi
fi

create_passed_junit "$JUNIT_SUITE" "$JUNIT_TEST"

for MACHINE_CONFIG_POOL in ${MCO_CONF_DAY2_PINTARGETRELEASE_MCPS}; do
    debug "$MACHINE_CONFIG_POOL"
done
