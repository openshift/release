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

# PinnedImageSet feature is now GA - TechPreview check removed

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

function get_pinnedimageset_api_version() {
    # Check if v1alpha1 API is available
    if oc api-resources --api-group=machineconfiguration.openshift.io | grep -q "pinnedimagesets.*v1alpha1"; then
        echo "machineconfiguration.openshift.io/v1alpha1"
    else
        echo "machineconfiguration.openshift.io/v1"
    fi
}

# Detect the appropriate API version
PINNEDIMAGESET_API_VERSION=$(get_pinnedimageset_api_version)
echo "Using PinnedImageSet API version: ${PINNEDIMAGESET_API_VERSION}"

# Writing the PinnedImageSet files
for MACHINE_CONFIG_POOL in ${MCO_CONF_DAY2_PINTARGETRELEASE_MCPS}; do
    file=$(get_pinned_image_file "${MACHINE_CONFIG_POOL}")
    echo "Rendering PinnedImageSet for pool ${MACHINE_CONFIG_POOL}"


    cat << EOF >> "${file}"
apiVersion: ${PINNEDIMAGESET_API_VERSION}
kind: PinnedImageSet
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${MACHINE_CONFIG_POOL}
  name: 99-${MACHINE_CONFIG_POOL}-pinned-release
spec:
  pinnedImages:
$(oc adm release info "${TARGET}" -a "${CLUSTER_PROFILE_DIR}"/pull-secret -o pullspec | awk '{print "   - name: " $1}'| sort | uniq)
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
        # Create valid empty dockerconfig JSON and update the secret
        # The pull-secret must be valid JSON with empty auths, not null or bare {}
        EMPTY_DOCKERCONFIG=$(echo -n '{"auths":{}}' | base64 -w0)
        oc patch secret/pull-secret -n openshift-config -p "{\"data\":{\".dockerconfigjson\":\"${EMPTY_DOCKERCONFIG}\"}}"

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

# Set ImageStreamTags to reference mode for debugging/validation purposes.
# This forces these images to be pulled from external registry or use pinned cached versions
# rather than the internal registry. This validates that pinned images are accessible,
# especially after the pull-secret has been removed. Useful for debugging with tools like
# oc debug, must-gather, and network-tools to ensure image pinning is working correctly.
image_list=("cli" "cli-artifacts" "installer" "installer-artifacts" "tests" "tools" "must-gather" "oauth-proxy" "network-tools")

for img in "${image_list[@]}"; do
  if oc get imagestreamtags ${img}:latest -n openshift &>/dev/null; then
    echo "Patching imagestreamtag ${img}:latest to reference mode"
    oc patch imagestreamtags ${img}:latest -n openshift --type json -p '[{"op": "add", "path": "/tag/reference", "value": true}]'
  else
    echo "Skipping imagestreamtag ${img}:latest (not found)"
  fi
done

create_passed_junit "$JUNIT_SUITE" "$JUNIT_TEST"

for MACHINE_CONFIG_POOL in ${MCO_CONF_DAY2_PINTARGETRELEASE_MCPS}; do
    debug "$MACHINE_CONFIG_POOL"
done
