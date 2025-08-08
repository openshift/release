#!/bin/bash
set -euo pipefail

# Define all valid capabilities
VALID_CAPABILITIES=("Console" "ImageRegistry" "Insights" "NodeTuning" "baremetal" "openshift-samples" "Ingress")
DISABLED_CAPABILITIES=()

# Path to file where selected capability settings will be saved
HC_DISABLED_CAPS_SETTING="${SHARED_DIR}/HC_Disabling_Capabilities"

if [[ -n "${HC_DISABLED_CAPS:-}" ]]; then
  echo "Using ENV var HC_DISABLED_CAPS: ${HC_DISABLED_CAPS}"
  IFS=',' read -ra DISABLED_CAPABILITIES <<< "$HC_DISABLED_CAPS"
else
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
fi

# Enforce: If Ingress is disabled, Console must also be disabled
if [[ " ${DISABLED_CAPABILITIES[*]} " =~ " Ingress " && ! " ${DISABLED_CAPABILITIES[*]} " =~ " Console " ]]; then
  echo "Enforcing rule: Ingress is disabled, so Console must be disabled too."
  DISABLED_CAPABILITIES+=("Console")
fi

# Remove duplicates just in case
mapfile -t DISABLED_CAPABILITIES < <(printf "%s\n" "${DISABLED_CAPABILITIES[@]}" | sort -u)

# Convert to comma-separated string
HC_DISABLED_CAPS="$(IFS=','; echo "${DISABLED_CAPABILITIES[*]}")"

echo "Hosted Cluster Disabled Capabilities: ${HC_DISABLED_CAPS}"

# Write to file for other scripts to consume
echo "HC_DISABLED_CAPS=${HC_DISABLED_CAPS}" > "${HC_DISABLED_CAPS_SETTING}"
