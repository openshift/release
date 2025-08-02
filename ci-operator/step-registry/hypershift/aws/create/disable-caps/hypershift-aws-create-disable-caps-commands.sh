#!/bin/bash
set -euo pipefail

# Define all valid capabilities
VALID_CAPABILITIES=("Console" "ImageRegistry" "Insights" "NodeTuning" "baremetal" "openshift-samples" "Ingress")
DISABLED_CAPABILITIES=()

# Path to file where selected capability settings will be saved
HC_DISABLED_CAPS_SETTING="${SHARED_DIR}/HC_Disabling_Capabilities"

# Randomly select a subset of capabilities to disable
for cap in "${VALID_CAPABILITIES[@]}"; do
  if (( RANDOM % 2 )); then
    DISABLED_CAPABILITIES+=("$cap")
  fi
done

# Ensure at least one capability is disabled
if [[ "${#DISABLED_CAPABILITIES[@]}" -eq 0 ]]; then
  random_index=$((RANDOM % ${#VALID_CAPABILITIES[@]}))
  DISABLED_CAPABILITIES+=("${VALID_CAPABILITIES[$random_index]}")
fi

# Enforce: If Ingress is disabled, Console must also be disabled
if [[ " ${DISABLED_CAPABILITIES[*]} " =~ " Ingress " && ! " ${DISABLED_CAPABILITIES[*]} " =~ " Console " ]]; then
  DISABLED_CAPABILITIES+=("Console")
fi

# Convert arrays to comma-separated strings
VALID_CAPS_CSV="$(IFS=','; echo "${VALID_CAPABILITIES[*]}")"
DISABLED_CAPS_CSV="$(IFS=','; echo "${DISABLED_CAPABILITIES[*]}")"

echo "Hosted Cluster Disalbed Capabilities: ${DISABLED_CAPS_CSV}"

# Write settings to shared file for later steps
echo "HC_DISABLED_CAPS=${DISABLED_CAPS_CSV}" >> "${HC_DISABLED_CAPS_SETTING}"