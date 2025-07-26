 #!/bin/bash
set -euo pipefail

VALID_CAPS=("Console" "ImageRegistry" "Insights" "NodeTuning" "baremetal" "openshift-samples" "Ingress")
SELECTED_CAPS=()

# Randomly select caps
for cap in "${VALID_CAPS[@]}"; do
  if (( RANDOM % 2 )); then
    SELECTED_CAPS+=("$cap")
  fi
done

# Ensure at least one capability is selected
if [[ "${#SELECTED_CAPS[@]}" -eq 0 ]]; then
  RANDOM_INDEX=$((RANDOM % ${#VALID_CAPS[@]}))
  SELECTED_CAPS+=("${VALID_CAPS[$RANDOM_INDEX]}")
fi

# Ensure Console is included if Ingress is selected
if [[ " ${SELECTED_CAPS[*]} " =~ " Ingress " && ! " ${SELECTED_CAPS[*]} " =~ " Console " ]]; then
  SELECTED_CAPS+=("Console")
fi

HC_DISABLE_CAPS="$(IFS=','; echo "${SELECTED_CAPS[*]}")"
echo "Generated HC_DISABLE_CAPS=${HC_DISABLE_CAPS}"

# Export to SHARED_DIR for other steps to use
echo "HC_DISABLE_CAPS=${HC_DISABLE_CAPS}" >> "${SHARED_DIR}/env"
