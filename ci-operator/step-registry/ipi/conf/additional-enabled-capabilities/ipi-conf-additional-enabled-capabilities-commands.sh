#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

if [[ -z "${ADDITIONAL_ENABLED_CAPABILITY_SET}" ]]; then
    echo "Not set envrionment variable ADDITIONAL_ENABLED_CAPABILITY_SET, exiting"
    exit 1
fi

baseline_check=$(yq-go r "${CONFIG}" "capabilities.baselineCapabilitySet")
if [[ -z "${baseline_check}" ]]; then
    echo "additionalEnabledCapabilities extends the additional capabililities beyoind what you set in baselineCapabilitySet, please also set envrionment variable BASELINE_CAPABILITY_SET, exiting"
    exit 1
fi

#add parameter additionalEnabledCapabilities into install-config.yaml file
for op in ${ADDITIONAL_ENABLED_CAPABILITY_SET}; do
    yq-go w --style tagged -i "${CONFIG}" 'capabilities.additionalEnabledCapabilities[+]' "${op}"
done

echo "capability setting in ${CONFIG} is as below:"
yq-go r "${CONFIG}" capabilities
