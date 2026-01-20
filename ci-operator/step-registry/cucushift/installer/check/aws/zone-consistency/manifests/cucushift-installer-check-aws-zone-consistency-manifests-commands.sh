#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# post check steps after manifest generation, exit code 100 if failed,
# save to install-pre-config-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

# Try to find installer directory
# First check SHARED_DIR (manifests copied from ipi-install-install step)
# Then check /tmp/installer (if running in the same pod)
if [ -d "${SHARED_DIR}/installer" ]; then
  INSTALL_DIR="${SHARED_DIR}/installer"
elif [ -d "/tmp/installer" ]; then
  INSTALL_DIR="/tmp/installer"
else
  echo "Error: Installation directory not found in ${SHARED_DIR}/installer or /tmp/installer"
  exit 1
fi

CAPI_FILES=$(find "$INSTALL_DIR"/openshift -name "*cluster-api*master*.yaml" -type f 2>/dev/null | sort || true)
MAPI_FILES=$(find "$INSTALL_DIR"/openshift -name "*machine-api*master*.yaml" -type f 2>/dev/null | sort || true)

if [ -z "$CAPI_FILES" ]; then
  echo "Error: CAPI manifest files not found"
  exit 1
fi

if [ -z "$MAPI_FILES" ]; then
  echo "Error: MAPI manifest files not found"
  exit 1
fi

# Get CAPI zones
capi_zones=()
for file in $CAPI_FILES; do
  zone=$(yq eval '.spec.providerSpec.value.placement.availabilityZone' "$file" 2>/dev/null || echo "")
  if [ -n "$zone" ] && [ "$zone" != "null" ]; then
    capi_zones+=("$zone")
  fi
done

if [ ${#capi_zones[@]} -eq 0 ]; then
  echo "Error: No CAPI zone information found"
  exit 1
fi

# Get MAPI zones
mapi_zones=()
for file in $MAPI_FILES; do
  kind=$(yq eval '.kind' "$file" 2>/dev/null || echo "")
  if [ "$kind" = "ControlPlaneMachineSet" ]; then
    zones=$(yq eval '.spec.template.machines_v1beta1_machine_openshift_io.failureDomains.aws[].placement.availabilityZone' "$file" 2>/dev/null || echo "")
    master_count=${#capi_zones[@]}
    mapi_index=0
    for zone in $zones; do
      if [ "$zone" != "null" ] && [ -n "$zone" ] && [ $mapi_index -lt "$master_count" ]; then
        mapi_zones+=("$zone")
        mapi_index=$((mapi_index + 1))
      fi
    done
  fi
done

if [ ${#mapi_zones[@]} -eq 0 ]; then
  echo "Error: No MAPI zone information found"
  exit 1
fi

# Compare zones
ret=0
for i in $(seq 0 $((${#capi_zones[@]} - 1))); do
  capi_zone="${capi_zones[$i]}"
  mapi_zone="${mapi_zones[$i]}"
  if [ "$capi_zone" != "$mapi_zone" ]; then
    echo "ERROR: master-$i zone mismatch - CAPI: $capi_zone, MAPI: $mapi_zone"
    ret=$((ret + 1))
  fi
done

if [ $ret -eq 0 ]; then
  echo "PASS: All machines have consistent zone allocation"
else
  echo "FAIL: Zone allocation inconsistency detected"
fi

exit $ret
