#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

if [ -f "${SHARED_DIR}/kubeconfig" ]; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
    echo "ERROR: fail to get the kubeconfig file under ${SHARED_DIR}!!"
    exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"

# Check if imageDigestSources is configured in install-config.yaml
num_sources=$(yq-go r "${INSTALL_CONFIG}" 'imageDigestSources' -l)

if [[ "${num_sources}" == "0" ]] || [[ -z "${num_sources}" ]]; then
    echo "No imageDigestSources configured in install-config.yaml, skip the post check..."
    exit 0
fi

echo "Found ${num_sources} imageDigestSources entries in install-config.yaml"

# Check if any sourcePolicy is configured
has_source_policy=false
for ((i=0; i<num_sources; i++)); do
    source_policy=$(yq-go r "${INSTALL_CONFIG}" "imageDigestSources[$i].sourcePolicy")
    if [[ -n "${source_policy}" ]]; then
        has_source_policy=true
        echo "imageDigestSources[$i] has sourcePolicy: ${source_policy}"
    fi
done

if [[ "${has_source_policy}" == "false" ]]; then
    echo "No sourcePolicy configured in any imageDigestSources, skip the post check..."
    exit 0
fi

echo "------Checking ImageDigestMirrorSet in the cluster------"

# Check if ImageDigestMirrorSet resources exist
idms_count=$(oc get imagedigestmirrorset --no-headers 2>/dev/null | wc -l | xargs)

if [[ "${idms_count}" == "0" ]]; then
    echo "ERROR: No ImageDigestMirrorSet resources found in the cluster"
    exit 1
fi

echo "Found ${idms_count} ImageDigestMirrorSet resource(s) in the cluster"

check_result=0

# Verify each imageDigestSource from install-config has corresponding IDMS with correct sourcePolicy
for ((i=0; i<num_sources; i++)); do
    source=$(yq-go r "${INSTALL_CONFIG}" "imageDigestSources[$i].source")
    expected_policy=$(yq-go r "${INSTALL_CONFIG}" "imageDigestSources[$i].sourcePolicy")

    if [[ -z "${expected_policy}" ]]; then
        echo "imageDigestSources[$i] (source: ${source}) has no sourcePolicy configured, skipping..."
        continue
    fi

    echo ""
    echo "Checking imageDigestSources[$i]:"
    echo "  Source: ${source}"
    echo "  Expected sourcePolicy: ${expected_policy}"

    # Get all IDMS and check for matching source with correct policy
    idms_list=$(oc get imagedigestmirrorset -o json | jq -r '.items[].metadata.name')

    found_match=false
    for idms_name in ${idms_list}; do
        # Check if this IDMS contains our source
        mirrors=$(oc get imagedigestmirrorset "${idms_name}" -o json | jq -r ".spec.imageDigestMirrors[] | select(.source == \"${source}\")")

        if [[ -n "${mirrors}" ]]; then
            actual_policy=$(echo "${mirrors}" | jq -r '.mirrorSourcePolicy // "AllowContactingSource"')
            echo "  Found in IDMS '${idms_name}' with mirrorSourcePolicy: ${actual_policy}"

            if [[ "${actual_policy}" == "${expected_policy}" ]]; then
                echo "  ✓ Source policy matches expected value"
                found_match=true
            else
                echo "  ✗ ERROR: Source policy mismatch! Expected '${expected_policy}' but got '${actual_policy}'"
                check_result=1
            fi
            break
        fi
    done

    if [[ "${found_match}" == "false" ]]; then
        echo "  ✗ ERROR: Source '${source}' not found in any ImageDigestMirrorSet"
        check_result=1
    fi
done

echo ""
if [[ "${check_result}" == "0" ]]; then
    echo "✓ All imageDigestSources source policies are correctly configured in the cluster"
else
    echo "✗ Some imageDigestSources source policies are not correctly configured"
fi

exit ${check_result}
